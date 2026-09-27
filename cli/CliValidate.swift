// `compositor validate` — the authoritative ProjectStore verdict plus a
// per-rule diagnostic pass that reports every violation it can find. The app's
// own validation stops at the first failure and gives no feedback over the
// file-watcher path; this exists so agents (and scripts) get the whole list.

import AppKit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct Finding: Codable {
    var severity: String // "error" | "warning"
    var code: String
    var layer: String?
    var message: String
}

struct ValidateReport: Codable {
    var file: String
    var ok: Bool
    var storeLoadOK: Bool
    var storeError: String?
    var findings: [Finding]
}

enum ValidateCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first else {
            FileHandle.standardError.write(Data("validate: pass a .comp package path\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: path)
        var findings: [Finding] = []
        var storeOK = true
        var storeError: String?

        // Stage 1: manifest decode with precise coding-path reporting.
        let metadataURL = url.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            report(url: path, ok: false, storeOK: false,
                   storeError: "manifest.json not found", findings: [Finding(
                        severity: "error", code: "manifest.missing", layer: nil,
                        message: "The package has no manifest.json.")], options)
            return
        }
        let data = try Data(contentsOf: metadataURL)
        let manifest: ProjectManifest
        do {
            manifest = try JSONDecoder().decode(ProjectManifest.self, from: data)
        } catch let error as DecodingError {
            let detail: String
            switch error {
            case .dataCorrupted(let ctx): detail = ctx.debugDescription
            case .keyNotFound(let key, let ctx): detail = "missing key '\(key.stringValue)' at \(ctx.codingPath.map(\.stringValue))"
            case .typeMismatch(let type, let ctx): detail = "expected \(type) at \(ctx.codingPath.map(\.stringValue))"
            case .valueNotFound(let type, let ctx): detail = "null \(type) at \(ctx.codingPath.map(\.stringValue))"
            @unknown default: detail = String(describing: error)
            }
            report(url: path, ok: false, storeOK: false,
                   storeError: "manifest.json is not decodable", findings: [Finding(
                        severity: "error", code: "manifest.decode", layer: nil,
                        message: "The manifest cannot be decoded: \(detail).")], options)
            return
        }

        // Stage 2: per-rule diagnostics — mirrors ProjectStore.validate, but keeps going.
        lint(manifest, url: url, into: &findings)

        // Stage 3: the authoritative verdict, straight from the app's store.
        do {
            _ = try await ProjectStore.shared.load(from: url)
        } catch {
            storeOK = false
            storeError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            findings.append(Finding(severity: "error", code: "store.load", layer: nil,
                                    message: storeError ?? ""))
        }

        let ok = storeOK && !findings.contains { $0.severity == "error" }
        report(url: path, ok: ok, storeOK: storeOK, storeError: storeError, findings: findings, options)
    }

    static func report(url: String, ok: Bool, storeOK: Bool, storeError: String?,
                       findings: [Finding], _ options: Options) {
        if options.flags["json"] != nil {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let report = ValidateReport(file: url, ok: ok, storeLoadOK: storeOK,
                                        storeError: storeError, findings: findings)
            print(String(data: try! encoder.encode(report), encoding: .utf8)!)
        } else {
            print("\(url): \(ok ? "OK" : "FAILED")")
            for finding in findings {
                let at = finding.layer.map { " [\($0)]" } ?? ""
                print("  \(finding.severity.uppercased()) \(finding.code)\(at): \(finding.message)")
            }
            if findings.isEmpty { print("  no findings") }
        }
        exit(ok ? 0 : 1)
    }

    // MARK: - Rule-by-rule pass

    static func finding(_ findings: inout [Finding], _ code: String, _ layer: ProjectLayerRecord?,
                        _ message: String) {
        findings.append(Finding(severity: "error", code: code, layer: layer?.id.uuidString, message: message))
    }

    static func lint(_ manifest: ProjectManifest, url: URL, into findings: inout [Finding]) {
        if manifest.format != "com.compositor.project" {
            findings.append(Finding(severity: "error", code: "format", layer: nil,
                                    message: "format must be \"com.compositor.project\"."))
        }
        if !ProjectManifest.supported.contains(manifest.version) {
            findings.append(Finding(severity: "error", code: "version", layer: nil,
                                    message: "version \(manifest.version) is outside the supported \(ProjectManifest.supported.lowerBound)–\(ProjectManifest.supported.upperBound)."))
        }
        if manifest.colorSpace != "sRGB" {
            findings.append(Finding(severity: "error", code: "colorSpace", layer: nil,
                                    message: "colorSpace must be \"sRGB\"."))
        }
        if let resolution = manifest.resolution, !resolution.isFinite || !(1...9600).contains(resolution) {
            findings.append(Finding(severity: "error", code: "resolution", layer: nil,
                                    message: "resolution must be 1–9600 ppi."))
        }
        if !(1...DocumentLimits.maxSide).contains(manifest.width) || !(1...DocumentLimits.maxSide).contains(manifest.height) {
            findings.append(Finding(severity: "error", code: "canvas.size", layer: nil,
                                    message: "canvas is \(manifest.width)×\(manifest.height); each side must be 1–\(DocumentLimits.maxSide)."))
        }
        if manifest.layers.count > 10_000 {
            findings.append(Finding(severity: "error", code: "layers.count", layer: nil,
                                    message: "a project holds at most 10,000 layers."))
        }

        var seen = Set<UUID>()
        var imagePixels = 0, maskPixels = 0
        let byID = Dictionary(uniqueKeysWithValues: manifest.layers.map { ($0.id, $0) })
        let fileManager = FileManager.default

        for layer in manifest.layers {
            let name = layer.name
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                finding(&findings, "layer.name.empty", layer, "layer name is empty.")
            }
            if name.utf8.count > 16_384 {
                finding(&findings, "layer.name.long", layer, "layer name exceeds 16,384 UTF-8 bytes.")
            }
            if !seen.insert(layer.id).inserted {
                finding(&findings, "layer.id.duplicate", layer, "layer id is not unique.")
            }
            if !layer.transform.isValid {
                finding(&findings, "layer.transform", layer, "transform is not valid (finite origin/size, no zero size).")
            }
            if let imageFile = layer.imageFile, imageFile != "\(layer.id.uuidString).png" {
                finding(&findings, "layer.imageFile.name", layer,
                        "imageFile must be \"\(layer.id.uuidString).png\" (got \"\(imageFile)\").")
            }

            let opacity = layer.opacity ?? 1
            if !opacity.isFinite || !(0...1).contains(opacity) {
                finding(&findings, "layer.opacity", layer, "opacity must be 0–1.")
            }
            if manifest.version < 3, opacity != 1 || (layer.blendMode ?? .normal) != .normal {
                finding(&findings, "layer.appearance.v1", layer, "versions 1–2 require opacity 1 and Normal blend.")
            }
            if layer.isGroup == true, (layer.blendMode ?? .normal) != .normal {
                finding(&findings, "layer.folder.blend", layer, "folders are pass-through: blend mode must be Normal.")
            }
            if layer.isGroup == true, manifest.version < 8, opacity != 1 {
                finding(&findings, "layer.folder.opacity", layer, "folder opacity needs version 8.")
            }

            if let maskFile = layer.maskFile {
                let minimum = layer.isGroup == true ? 6 : 4
                if manifest.version < minimum {
                    finding(&findings, "layer.mask.version", layer, "masks need version \(minimum)+ (folder masks 6+).")
                }
                if maskFile != "\(layer.id.uuidString).mask.png" {
                    finding(&findings, "layer.maskFile.name", layer,
                            "maskFile must be \"\(layer.id.uuidString).mask.png\" (got \"\(maskFile)\").")
                }
            } else if layer.maskEnabled != nil {
                finding(&findings, "layer.maskEnabled", layer, "maskEnabled requires a maskFile.")
            }
            if let placement = layer.maskPlacement {
                if !placement.isValid || layer.maskFile == nil {
                    finding(&findings, "layer.maskPlacement", layer,
                            "maskPlacement needs a valid transform and an existing maskFile.")
                }
            }
            if manifest.version < 5, layer.maskSourceID != nil {
                finding(&findings, "layer.liveMask.version", layer, "clipping masks need version 5+.")
            }
            if let source = layer.maskSourceID {
                guard let owner = byID[source] else {
                    finding(&findings, "layer.liveMask.missing", layer, "maskSourceID points nowhere.")
                    continue
                }
                if owner.isGroup == true {
                    finding(&findings, "layer.liveMask.group", layer, "maskSourceID cannot point at a folder.")
                }
            }

            if let adjustment = layer.adjustment {
                if manifest.version < 7 {
                    finding(&findings, "layer.adjustment.version", layer, "adjustment layers need version 7+.")
                }
                if layer.isGroup == true {
                    finding(&findings, "layer.adjustment.group", layer, "adjustment layers cannot be folders.")
                }
                if layer.imageFile != nil {
                    finding(&findings, "layer.adjustment.image", layer, "adjustment layers cannot carry an imageFile.")
                }
                if !adjustment.isValid {
                    finding(&findings, "layer.adjustment.values", layer, "adjustment settings are out of range.")
                }
                if adjustment.kind == .gaussianBlur || adjustment.kind == .motionBlur || adjustment.kind == .addNoise,
                   manifest.version < 9 {
                    finding(&findings, "layer.adjustment.sampling", layer, "blur/noise adjustments need version 9+.")
                }
            }

            if let text = layer.text {
                if !text.isValid {
                    finding(&findings, "layer.text.values", layer, "text settings are out of range.")
                }
                if text.colorRuns != nil && manifest.version < 10 {
                    finding(&findings, "layer.text.colorRuns", layer, "colorRuns need version 10+.")
                }
                if text.fontRuns != nil && manifest.version < 11 {
                    finding(&findings, "layer.text.fontRuns", layer, "fontRuns need version 11+.")
                }
                if layer.imageFile == nil {
                    finding(&findings, "layer.text.image", layer, "a text layer needs rendered pixels (imageFile).")
                }
                if layer.isGroup == true || layer.adjustment != nil {
                    finding(&findings, "layer.text.kind", layer, "text cannot live on a folder or adjustment layer.")
                }
            }
        }

        if let error = firstHierarchyError(manifest) {
            findings.append(Finding(severity: "error", code: "hierarchy", layer: nil, message: error))
        }

        if let id = manifest.activeLayerID, !byID.keys.contains(id) {
            findings.append(Finding(severity: "error", code: "activeLayer", layer: nil,
                                    message: "activeLayerID does not match any layer."))
        }

        // Guides.
        if manifest.version < 8, (manifest.guides ?? []).isEmpty == false {
            findings.append(Finding(severity: "error", code: "guides.version", layer: nil, message: "guides need version 8+."))
        }
        var guideIDs = Set<UUID>()
        for guide in manifest.guides ?? [] {
            if !guideIDs.insert(guide.id).inserted {
                findings.append(Finding(severity: "error", code: "guides.duplicate", layer: nil, message: "duplicate guide id."))
            }
            if !guide.position.isFinite || abs(guide.position) > 1_000_000 {
                findings.append(Finding(severity: "error", code: "guides.position", layer: nil,
                                        message: "guide position must be finite and within ±1,000,000."))
            }
        }

        // Assets on disk: presence, format, depth, budget.
        for layer in manifest.layers {
            for (filename, isMask) in [(layer.imageFile, false), (layer.maskFile, true)] {
                guard let filename else { continue }
                let fileURL = url.appendingPathComponent("images").appendingPathComponent(filename)
                guard fileManager.fileExists(atPath: fileURL.path) else {
                    finding(&findings, isMask ? "asset.mask.missing" : "asset.image.missing", layer,
                            "\(filename) is missing from images/.")
                    continue
                }
                guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
                      CGImageSourceGetType(source) as String? == UTType.png.identifier else {
                    finding(&findings, isMask ? "asset.mask.format" : "asset.image.format", layer,
                            "\(filename) is not a PNG.")
                    continue
                }
                guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else {
                    finding(&findings, isMask ? "asset.mask.format" : "asset.image.format", layer,
                            "\(filename) has no readable pixel properties.")
                    continue
                }
                if (properties[kCGImagePropertyDepth] as? Int ?? 8) > 8 {
                    finding(&findings, isMask ? "asset.mask.depth" : "asset.image.depth", layer,
                            "\(filename) is deeper than 8 bits per component.")
                }
                if isMask {
                    if !(1...DocumentLimits.maxSide).contains(width) || !(1...DocumentLimits.maxSide).contains(height)
                        || width * height > DocumentLimits.documentPixelBudget - maskPixels {
                        finding(&findings, "asset.mask.size", layer,
                                "\(filename) is \(width)×\(height); it exceeds the pixel budget.")
                    }
                    maskPixels += width * height
                } else {
                    if !(1...DocumentLimits.maxSide).contains(width) || !(1...DocumentLimits.maxSide).contains(height)
                        || width * height > DocumentLimits.documentPixelBudget - imagePixels {
                        finding(&findings, "asset.image.size", layer,
                                "\(filename) is \(width)×\(height); it exceeds the pixel budget.")
                    }
                    imagePixels += width * height
                }
            }
        }
    }

    static func firstHierarchyError(_ manifest: ProjectManifest) -> String? {
        do {
            try LayerHierarchy.validate(manifest.layers)
            try LiveMaskGraph.validate(manifest.layers)
            return nil
        } catch let error as LocalizedError {
            return error.errorDescription ?? String(describing: error)
        } catch {
            return String(describing: error)
        }
    }
}
