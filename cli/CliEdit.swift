// Fine-grained editing commands. Every mutation follows the same proven
// pattern: ProjectStore.load → rebuild the snapshot → ProjectStore.save, which
// validates the whole package and replaces it atomically. No GUI code here.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Shared helpers

/// Rebuilds a record — its identity and transform fields are `let`, so changes
/// go through a full memberwise copy.
func reRecord(_ l: ProjectLayerRecord, id: UUID? = nil, name: String? = nil,
              imageFile: String? = nil, maskFile: String? = nil,
              transform: LayerTransform? = nil,
              change: (inout ProjectLayerRecord) -> Void = { _ in }) -> ProjectLayerRecord {
    var copy = ProjectLayerRecord(id: id ?? l.id, name: name ?? l.name, isVisible: l.isVisible,
                                  transform: transform ?? l.transform, imageFile: imageFile ?? l.imageFile,
                                  parentID: l.parentID, isGroup: l.isGroup, opacity: l.opacity,
                                  blendMode: l.blendMode, maskFile: maskFile ?? l.maskFile,
                                  maskEnabled: l.maskEnabled, maskSourceID: l.maskSourceID,
                                  adjustment: l.adjustment, maskPlacement: l.maskPlacement,
                                  maskLinked: l.maskLinked, shape: l.shape, effects: l.effects, text: l.text)
    change(&copy)
    return copy
}

func updatingManifest(_ snapshot: ProjectSnapshot, _ change: (inout ProjectManifest) -> Void) -> ProjectSnapshot {
    var manifest = snapshot.manifest
    change(&manifest)
    return ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks)
}

func resolveLayer(_ selector: String, in manifest: ProjectManifest) -> UUID? {
    if let id = UUID(uuidString: selector), manifest.layers.contains(where: { $0.id == id }) {
        return id
    }
    let exact = manifest.layers.filter { $0.name == selector }
    if exact.count == 1 { return exact[0].id }
    if exact.count > 1 {
        FileHandle.standardError.write(Data(
            "layer name \"\(selector)\" matches \(exact.count) layers; use a UUID:\n".utf8))
        for layer in exact {
            FileHandle.standardError.write(Data("  \(layer.id)  \(layer.name)\n".utf8))
        }
        exit(1)
    }
    let loose = manifest.layers.filter { $0.name.lowercased() == selector.lowercased() }
    if loose.count == 1 { return loose[0].id }
    if loose.count > 1 {
        FileHandle.standardError.write(Data(
            "layer name \"\(selector)\" matches \(loose.count) layers case-insensitively; use a UUID\n".utf8))
        exit(1)
    }
    return nil
}

func subtreeIDs(of id: UUID, in manifest: ProjectManifest) -> Set<UUID> {
    var ids = Set<UUID>([id])
    var grew = true
    while grew {
        grew = false
        for layer in manifest.layers where layer.parentID.map({ ids.contains($0) }) == true && !ids.contains(layer.id) {
            ids.insert(layer.id)
            grew = true
        }
    }
    return ids
}

func parsePoint(_ spec: String) -> CGPoint? {
    let parts = spec.split(separator: ",").compactMap { Double($0) }
    guard parts.count == 2 else { return nil }
    return CGPoint(x: parts[0], y: parts[1])
}

func parseSize(_ spec: String) -> CGSize? {
    guard let point = parsePoint(spec), point.x >= 1, point.y >= 1 else { return nil }
    return CGSize(width: point.x, height: point.y)
}

func done(_ options: Options, _ message: String) {
    if options.flags["json"] != nil {
        jsonOutput(["ok": true, "message": message])
    } else {
        print(message)
    }
}

// MARK: - layers (tree listing)

enum LayersCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first else {
            FileHandle.standardError.write(Data("layers: pass a .comp package path\n".utf8))
            exit(2)
        }
        let snapshot = try await ProjectStore.shared.load(from: URL(fileURLWithPath: path))
        let manifest = snapshot.manifest
        let byParent = Dictionary(grouping: manifest.layers) { $0.parentID }

        var rows: [[String: Any]] = []
        func visit(parent: UUID?, depth: Int, visible: Bool, opacity: Double) {
            for layer in byParent[parent] ?? [] {
                let kind: String
                if let adjustment = layer.adjustment {
                    kind = "adjustment(\(adjustment.kind.rawValue))"
                } else if layer.isGroup == true {
                    kind = "folder"
                } else if layer.text != nil {
                    kind = "text"
                } else {
                    kind = "image"
                }
                let isVisible = visible && layer.isVisible
                let effective = opacity * (layer.opacity ?? 1)
                rows.append([
                    "id": layer.id.uuidString,
                    "name": layer.name,
                    "depth": depth,
                    "kind": kind,
                    "visible": isVisible,
                    "opacity": effective,
                    "blend": layer.blendMode?.rawValue ?? "Normal",
                    "size": "\(Int(layer.transform.size.width))×\(Int(layer.transform.size.height))",
                    "origin": "\(Int(layer.transform.origin.x)),\(Int(layer.transform.origin.y))",
                    "mask": layer.maskFile != nil ? (layer.maskEnabled == false ? "off" : "on") : nil,
                    "clipped": layer.maskSourceID != nil,
                ])
                if layer.isGroup == true {
                    visit(parent: layer.id, depth: depth + 1, visible: isVisible, opacity: effective)
                }
            }
        }
        visit(parent: nil, depth: 0, visible: true, opacity: 1)

        if options.flags["json"] != nil {
            jsonOutput(["canvas": "\(manifest.width)×\(manifest.height)", "layers": rows])
        } else {
            print("\(manifest.width)×\(manifest.height), bottom → top:")
            for row in rows {
                let indent = String(repeating: "  ", count: (row["depth"] as? Int) ?? 0)
                let hidden = (row["visible"] as? Bool ?? true) ? "" : "(hidden) "
                print("  \(indent)\(row["name"] ?? "") — \(row["kind"] ?? "") \(hidden)\(row["blend"] ?? "") \(row["origin"] ?? "") \(row["size"] ?? "")")
            }
        }
    }
}

// MARK: - adjustments (schema introspection)

enum AdjustmentsCommand {
    static func run(_ args: [String]) throws {
        let options = Options(args)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let requested = options.list.first {
            guard let kind = AdjustmentKind(rawValue: requested) else {
                FileHandle.standardError.write(Data(
                    "adjustments: unknown kind \"\(requested)\". Kinds: \(AdjustmentKind.allCases.map(\.rawValue).joined(separator: ", "))\n".utf8))
                exit(2)
            }
            // A default-materialized adjustment IS the schema: every field the
            // app reads, filled with the values a new layer starts with.
            let data = try encoder.encode(LayerAdjustment(kind: kind))
            print(String(data: data, encoding: .utf8)!)
            return
        }
        if options.flags["json"] != nil {
            jsonOutput(["kinds": AdjustmentKind.allCases.map(\.rawValue)])
        } else {
            print(AdjustmentKind.allCases.map(\.rawValue).joined(separator: "\n"))
        }
    }
}

// MARK: - set

enum SetCommand {
    // Text fields (--content/--font/--color/--align/--tracking/--leading/--box/
    // --font-size) re-render the layer's pixels through the same rasterizer the
    // `text` command uses; --size stays the transform box, as documented.
    static let knownFlags: Set<String> = ["layer", "name", "visible", "opacity", "blend",
                                          "origin", "size", "rotation", "flip-x", "flip-y", "sampling",
                                          "content", "font", "color", "align", "tracking", "leading",
                                          "box", "font-size", "json"]

    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first, let selector = options.flags["layer"] else {
            FileHandle.standardError.write(Data("set: pass <pkg> --layer <sel> and at least one field\n".utf8))
            exit(2)
        }
        let unknown = Set(options.flags.keys).subtracting(knownFlags)
        guard unknown.isEmpty else {
            FileHandle.standardError.write(Data(
                "set: unknown option(s) --\(unknown.sorted().joined(separator: ", --"))\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: path)
        var snapshot = try await ProjectStore.shared.load(from: url)
        guard let id = resolveLayer(selector, in: snapshot.manifest) else { fail("no layer matches \"\(selector)\"") }

        snapshot = updatingManifest(snapshot) { manifest in
            manifest.layers = manifest.layers.map { layer in
                guard layer.id == id else { return layer }
                return reRecord(layer, name: options.flags["name"]) { record in
                    if let visible = options.flags["visible"] { record.isVisible = visible == "on" || visible == "true" }
                    if let opacity = options.flags["opacity"], let value = Double(opacity) { record.opacity = value }
                    if let blend = options.flags["blend"] { record.blendMode = LayerBlendMode(rawValue: blend) }
                }
            }
        }

        // Restyling text re-renders its pixels (the PNG is the display and
        // export fallback, so metadata-only changes would never show).
        let textFlags = ["content", "font", "color", "align", "tracking", "leading", "box", "font-size"]
        if textFlags.contains(where: { options.flags[$0] != nil }) {
            if options.flags["size"] != nil {
                fail("--size is the transform box; use --box for text wrapping")
            }
            guard var style = snapshot.manifest.layers.first(where: { $0.id == id })?.text else {
                fail("text fields need a text layer (see the `text` command)")
            }
            if let content = options.flags["content"], !content.isEmpty { style.content = content }
            if let fontName = options.flags["font"] { style.fontName = fontName }
            if let size = options.flags["font-size"], let value = Double(size) { style.fontSize = CGFloat(value) }
            if let color = options.flags["color"], let rgb = parseHexColor(color) {
                style.red = rgb.0; style.green = rgb.1; style.blue = rgb.2
            }
            if let align = options.flags["align"], let value = TextAlignment(rawValue: align.capitalized) {
                style.alignment = value
            }
            if let tracking = options.flags["tracking"], let value = Double(tracking) { style.tracking = CGFloat(value) }
            if let leading = options.flags["leading"], let value = Double(leading) { style.leading = CGFloat(value) }
            if let box = options.flags["box"] {
                let parts = box.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2, parts[0] >= 16, parts[1] >= 16 else {
                    fail("--box expects <w,h> in pixels (minimum 16)")
                }
                style.boxSize = CGSize(width: parts[0], height: parts[1])
            }
            guard style.isValid else {
                fail("text settings are out of range (fontSize 1–2000, tracking −100–1000, leading 0–5000, color 0–1)")
            }
            let image = try TextRasterizer.image(style)
            var images = snapshot.images
            images[id] = ImportedImage(image: image, thumbnail: image,
                                       name: snapshot.manifest.layers.first(where: { $0.id == id })?.name ?? "")
            snapshot = updatingManifest(snapshot) { manifest in
                manifest.layers = manifest.layers.map { layer in
                    guard layer.id == id else { return layer }
                    // The pixels render at the style's natural size unless a
                    // paragraph box wraps them; the origin stays put.
                    let pixelSize = style.boxSize ?? CGSize(width: image.width, height: image.height)
                    let old = layer.transform
                    return reRecord(layer, transform: LayerTransform(
                        origin: old.origin, size: pixelSize, rotation: old.rotation,
                        flipX: old.flipX, flipY: old.flipY, sampling: old.sampling)) { $0.text = style }
                }
            }
            snapshot = ProjectSnapshot(manifest: snapshot.manifest, images: images, masks: snapshot.masks)
        }

        // The transform is immutable on the record, so rebuild it from overrides.
        if options.flags["origin"] != nil || options.flags["size"] != nil || options.flags["rotation"] != nil
            || options.flags["flip-x"] != nil || options.flags["flip-y"] != nil || options.flags["sampling"] != nil {
            let old = snapshot.manifest.layers.first { $0.id == id }!.transform
            let updated = updatingManifest(snapshot) { manifest in
                manifest.layers = manifest.layers.map { layer in
                    guard layer.id == id else { return layer }
                    return reRecord(layer, transform: LayerTransform(
                        origin: options.flags["origin"].flatMap(parsePoint) ?? old.origin,
                        size: options.flags["size"].flatMap(parseSize) ?? old.size,
                        rotation: options.flags["rotation"].flatMap(Double.init) ?? old.rotation,
                        flipX: options.flags["flip-x"].map { $0 == "on" || $0 == "true" } ?? old.flipX,
                        flipY: options.flags["flip-y"].map { $0 == "on" || $0 == "true" } ?? old.flipY,
                        sampling: options.flags["sampling"].flatMap { LayerSampling(rawValue: $0) } ?? old.sampling))
                }
            }
            snapshot = updated
        }
        try await ProjectStore.shared.save(snapshot, to: url)
        done(options, "layer \(id) updated")
    }
}

// MARK: - move / remove / duplicate / group

enum MoveCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first, let selector = options.flags["layer"] else {
            FileHandle.standardError.write(Data("move: pass <pkg> --layer <sel> and a position (--above/--below/--top/--bottom/--index)\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: path)
        var snapshot = try await ProjectStore.shared.load(from: url)
        guard let id = resolveLayer(selector, in: snapshot.manifest) else { fail("no layer matches \"\(selector)\"") }

        let moving = subtreeIDs(of: id, in: snapshot.manifest)
        var layers = snapshot.manifest.layers
        let movingRecords = layers.filter { moving.contains($0.id) }
        var remaining = layers.filter { !moving.contains($0.id) }

        if let parentSpec = options.flags["parent"], parentSpec != "root" {
            guard let parentID = resolveLayer(parentSpec, in: snapshot.manifest),
                  let parent = snapshot.manifest.layers.first(where: { $0.id == parentID }),
                  parent.isGroup == true else {
                fail("--parent must name a folder (or use --parent root)")
            }
            remaining = remaining.map { layer in
                moving.contains(layer.id) ? reRecord(layer) { $0.parentID = parentID } : layer
            }
        } else {
            layers = remaining
        }

        // Position names are z-order terms and the layers listing runs bottom →
        // top, so --top ends up last in the array and --above inserts after the
        // anchor. --index counts the same way, 0 = bottom.
        let insertion: Int
        if options.flags["top"] != nil {
            insertion = remaining.count
        } else if options.flags["bottom"] != nil {
            insertion = 0
        } else if let index = options.flags["index"], let n = Int(index) {
            insertion = max(0, min(remaining.count, n))
        } else if let anchor = options.flags["above"] ?? options.flags["below"] {
            guard let anchorID = resolveLayer(anchor, in: snapshot.manifest),
                  let anchorIndex = remaining.firstIndex(where: { $0.id == anchorID }) else {
                fail("--above/--below target not found in the remaining stack")
            }
            insertion = options.flags["above"] != nil ? anchorIndex + 1 : anchorIndex
        } else {
            fail("move needs --above, --below, --top, --bottom or --index")
        }
        remaining.insert(contentsOf: movingRecords, at: insertion)

        snapshot = ProjectSnapshot(
            manifest: manifestWith(snapshot.manifest, activeLayerID: snapshot.manifest.activeLayerID, layers: remaining),
            images: snapshot.images, masks: snapshot.masks)
        try await ProjectStore.shared.save(snapshot, to: url)
        done(options, "moved \(id)")
    }
}

enum RemoveCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first, let selector = options.flags["layer"] else {
            FileHandle.standardError.write(Data("remove: pass <pkg> --layer <sel>\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: path)
        var snapshot = try await ProjectStore.shared.load(from: url)
        guard let id = resolveLayer(selector, in: snapshot.manifest) else { fail("no layer matches \"\(selector)\"") }

        let doomed = subtreeIDs(of: id, in: snapshot.manifest)
        let removedCount = doomed.count
        let remaining = snapshot.manifest.layers.filter { !doomed.contains($0.id) }
        let newActive = snapshot.manifest.activeLayerID
            .flatMap { active in remaining.contains(where: { $0.id == active }) ? active : nil }
            ?? remaining.last?.id
        snapshot = ProjectSnapshot(
            manifest: manifestWith(snapshot.manifest, activeLayerID: newActive, layers: remaining),
            images: snapshot.images, masks: snapshot.masks)
        // Assets fall out of images/masks; save() replaces the whole package,
        // so their PNGs disappear with the operation.
        try await ProjectStore.shared.save(snapshot, to: url)
        done(options, "removed \(removedCount) layer(s)")
    }
}

enum DuplicateCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first, let selector = options.flags["layer"] else {
            FileHandle.standardError.write(Data("duplicate: pass <pkg> --layer <sel>\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: path)
        var snapshot = try await ProjectStore.shared.load(from: url)
        guard let id = resolveLayer(selector, in: snapshot.manifest),
              let original = snapshot.manifest.layers.first(where: { $0.id == id }),
              let asset = snapshot.images[id] else {
            fail("no layer matches \"\(selector)\"")
        }
        guard original.isGroup != true else { fail("duplicating a folder is not supported yet") }

        let newID = UUID()
        var offset = CGPoint(x: 16, y: 16)
        if let spec = options.flags["offset"], let point = parsePoint(spec) { offset = point }
        let shifted = LayerTransform(origin: CGPoint(x: original.transform.origin.x + offset.x,
                                                     y: original.transform.origin.y + offset.y),
                                     size: original.transform.size, rotation: original.transform.rotation,
                                     flipX: original.transform.flipX, flipY: original.transform.flipY,
                                     sampling: original.transform.sampling)
        let copy = reRecord(original, id: newID, name: options.flags["name"] ?? "\(original.name) copy",
                            imageFile: "\(newID.uuidString).png",
                            maskFile: original.maskFile.map { _ in "\(newID.uuidString).mask.png" },
                            transform: shifted)
        var images = snapshot.images
        images[newID] = ImportedImage(image: asset.image, thumbnail: asset.thumbnail, name: copy.name)
        if let mask = snapshot.masks[id] {
            snapshot.masks[newID] = ImportedImage(image: mask.image, thumbnail: mask.thumbnail, name: mask.name)
        }
        snapshot = updatingManifest(snapshot) { manifest in
            guard let index = manifest.layers.firstIndex(where: { $0.id == id }) else { return }
            manifest.layers.insert(copy, at: manifest.layers.index(after: index))
        }
        snapshot = ProjectSnapshot(
            manifest: manifestWith(snapshot.manifest, activeLayerID: newID, layers: snapshot.manifest.layers),
            images: images, masks: snapshot.masks)
        try await ProjectStore.shared.save(snapshot, to: url)
        done(options, "duplicated \(id) → \(newID)")
    }
}

enum GroupCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first, let selectors = options.flags["layers"] else {
            FileHandle.standardError.write(Data("group: pass <pkg> --layers <sel,sel,...>\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: path)
        var snapshot = try await ProjectStore.shared.load(from: url)
        let selections = selectors.split(separator: ",").map(String.init)
        let ids = selections.compactMap { resolveLayer($0, in: snapshot.manifest) }
        guard ids.count == selections.count, !ids.isEmpty else { fail("some --layers entries match no layer") }

        let selected = snapshot.manifest.layers.filter { ids.contains($0.id) }
        guard Set(selected.map { $0.parentID }).count == 1 else {
            fail("all grouped layers must share the same parent")
        }

        let groupID = UUID()
        let folder = ProjectLayerRecord(id: groupID, name: options.flags["name"] ?? "Folder", isVisible: true,
                                        transform: LayerTransform(origin: CGPoint(x: 0, y: 0),
                                                                  size: CGSize(width: snapshot.manifest.width,
                                                                               height: snapshot.manifest.height)),
                                        imageFile: nil, parentID: selected.first?.parentID, isGroup: true)

        // Keep the subtree contiguous: folder, then members in their original
        // relative order, at the position of the lowest member.
        var layers = snapshot.manifest.layers
        let members = layers.filter { ids.contains($0.id) }
        let firstMemberIndex = layers.firstIndex { ids.contains($0.id) } ?? layers.count
        layers.removeSubrange(firstMemberIndex..<(firstMemberIndex + members.count))
        layers.insert(contentsOf: [folder] + members, at: firstMemberIndex)
        layers = layers.map { layer in ids.contains(layer.id) ? reRecord(layer) { $0.parentID = groupID } : layer }

        snapshot = ProjectSnapshot(
            manifest: manifestWith(snapshot.manifest, activeLayerID: snapshot.manifest.activeLayerID, layers: layers),
            images: snapshot.images, masks: snapshot.masks)
        try await ProjectStore.shared.save(snapshot, to: url)
        done(options, "grouped \(ids.count) layer(s) into \(groupID)")
    }
}

// MARK: - mask

enum MaskCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first, let selector = options.flags["layer"] else {
            FileHandle.standardError.write(Data("mask: pass <pkg> --layer <sel> and one of --image/--clear/--enable\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: path)
        var snapshot = try await ProjectStore.shared.load(from: url)
        guard let id = resolveLayer(selector, in: snapshot.manifest),
              let layerIndex = snapshot.manifest.layers.firstIndex(where: { $0.id == id }),
              let asset = snapshot.images[id] else {
            fail("no layer matches \"\(selector)\"")
        }

        var finding: String?
        if options.flags["clear"] != nil {
            snapshot = updatingManifest(snapshot) { manifest in
                manifest.layers[layerIndex] = reRecord(manifest.layers[layerIndex]) {
                    $0.maskFile = nil; $0.maskEnabled = nil; $0.maskPlacement = nil
                }
            }
            snapshot.masks[id] = nil
        } else if let enable = options.flags["enable"] {
            guard snapshot.manifest.layers[layerIndex].maskFile != nil else { fail("layer has no mask") }
            snapshot = updatingManifest(snapshot) { manifest in
                manifest.layers[layerIndex].maskEnabled = enable == "on" || enable == "true"
            }
        } else if let imagePath = options.flags["image"] {
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
                  let loaded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                fail("cannot read mask image \(imagePath)")
            }
            // Masks are 8-bit device-gray, no alpha, at the layer's pixel size.
            let w = asset.image.width, h = asset.image.height
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                fail("cannot create gray context")
            }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.draw(loaded, in: CGRect(x: 0, y: 0, width: w, height: h))
            if options.flags["invert"] != nil, let bytes = context.data {
                let p = bytes.assumingMemoryBound(to: UInt8.self)
                for row in 0..<h {
                    for x in 0..<w { p[row * context.bytesPerRow + x] = 255 - p[row * context.bytesPerRow + x] }
                }
            }
            guard let gray = context.makeImage(), LayerMask.isValid(gray) else { fail("mask conversion failed") }
            snapshot.masks[id] = ImportedImage(image: gray, thumbnail: gray, name: "Layer Mask")
            snapshot = updatingManifest(snapshot) { manifest in
                manifest.layers[layerIndex] = reRecord(manifest.layers[layerIndex],
                                                       maskFile: "\(id.uuidString).mask.png") {
                    $0.maskEnabled = true
                }
            }
        } else {
            finding = "mask needs --image <file>, --clear or --enable on|off"
        }
        if let finding { fail(finding) }
        try await ProjectStore.shared.save(snapshot, to: url)
        done(options, "mask updated on \(id)")
    }
}

// MARK: - import

enum ImportCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first, let imagePath = options.flags["image"] else {
            FileHandle.standardError.write(Data("import: pass <pkg> --image <file>\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: path)
        var snapshot = try await ProjectStore.shared.load(from: url)
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: imagePath) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            fail("cannot read image \(imagePath)")
        }

        let canvas = CGSize(width: snapshot.manifest.width, height: snapshot.manifest.height)
        var size = CGSize(width: image.width, height: image.height)
        let fit = options.flags["fit"] ?? "none"
        switch fit {
        case "contain":
            let scale = min(canvas.width / size.width, canvas.height / size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        case "cover":
            let scale = max(canvas.width / size.width, canvas.height / size.height)
            size = CGSize(width: size.width * scale, height: size.height * scale)
        case "stretch":
            size = canvas
        default: break
        }
        if let sizeSpec = options.flags["size"], let forced = parseSize(sizeSpec) { size = forced }

        let origin: CGPoint
        if let originSpec = options.flags["origin"], let point = parsePoint(originSpec) {
            origin = point
        } else if fit == "none" {
            origin = CGPoint(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2)
        } else {
            origin = .zero
        }

        let id = UUID()
        let name = options.flags["name"] ?? URL(fileURLWithPath: imagePath).deletingPathExtension().lastPathComponent
        var record = ProjectLayerRecord(id: id, name: name, isVisible: true,
                                        transform: LayerTransform(origin: origin, size: size),
                                        imageFile: "\(id.uuidString).png")
        if let opacity = options.flags["opacity"], let value = Double(opacity) { record.opacity = value }
        if let blend = options.flags["blend"] { record.blendMode = LayerBlendMode(rawValue: blend) }

        var images = snapshot.images
        images[id] = ImportedImage(image: image, thumbnail: image, name: name)
        let manifest = manifestWith(snapshot.manifest, activeLayerID: id, layers: snapshot.manifest.layers + [record])
        snapshot = ProjectSnapshot(manifest: manifest, images: images, masks: snapshot.masks)
        try await ProjectStore.shared.save(snapshot, to: url)
        done(options, "imported \"\(name)\" as \(id) at \(Int(origin.x)),\(Int(origin.y)) size \(Int(size.width))×\(Int(size.height))")
    }
}

// MARK: - canvas / image-size

enum CanvasCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first, let sizeSpec = options.flags["size"],
              let size = parseSize(sizeSpec) else {
            FileHandle.standardError.write(Data("canvas: pass <pkg> --size <w,h> [--anchor center|top-left|…]\n".utf8))
            exit(2)
        }
        let anchors = ["top-left", "top", "top-right", "left", "center", "right", "bottom-left", "bottom", "bottom-right"]
        var anchor = 4
        if let name = options.flags["anchor"] {
            guard let index = anchors.firstIndex(of: name.lowercased()) else {
                fail("--anchor is one of: \(anchors.joined(separator: ", "))")
            }
            anchor = index
        }
        let url = URL(fileURLWithPath: path)
        var snapshot = try await ProjectStore.shared.load(from: url)
        snapshot = try await CanvasResizer.shared.resize(snapshot, to: CanvasSizeOptions(
            width: Int(size.width), height: Int(size.height), anchor: anchor))
        try await ProjectStore.shared.save(snapshot, to: url)
        done(options, "canvas resized to \(Int(size.width))×\(Int(size.height))")
    }
}

enum ImageSizeCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first, let sizeSpec = options.flags["size"],
              let size = parseSize(sizeSpec) else {
            FileHandle.standardError.write(Data("image-size: pass <pkg> --size <w,h> [--resolution ppi] [--sampling s]\n".utf8))
            exit(2)
        }
        let resolution = Double(options.flags["resolution"] ?? "") ?? 72
        let sampling = options.flags["sampling"].flatMap { LayerSampling(rawValue: $0) } ?? .high
        let url = URL(fileURLWithPath: path)
        var snapshot = try await ProjectStore.shared.load(from: url)
        snapshot = try await ImageResizer.shared.resize(snapshot, to: ImageSizeOptions(
            width: Int(size.width), height: Int(size.height), resolution: resolution, sampling: sampling))
        try await ProjectStore.shared.save(snapshot, to: url)
        done(options, "document resampled to \(Int(size.width))×\(Int(size.height)) @ \(Int(resolution))ppi")
    }
}
