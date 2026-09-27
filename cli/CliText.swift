// `compositor text` — add an editable text layer.
//
// Layout mirrors the app's `EditorSession.textImage` (TypeTool.swift) line for
// line: NSTextStorage + NSLayoutManager over a flipped NSGraphicsContext, with
// the same padding and box sizing, so the pixels an agent writes match what
// the app would render for the same `LayerTextStyle`. The `text` metadata is
// stored too, so the layer stays editable as real text in the app.

import AppKit
import CoreGraphics
import Foundation

enum TextCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first else {
            FileHandle.standardError.write(Data("text: pass a .comp package path\n".utf8))
            exit(2)
        }
        guard let content = options.flags["content"], !content.isEmpty else {
            FileHandle.standardError.write(Data("text: --content is required\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: path)
        var snapshot = try await ProjectStore.shared.load(from: url)

        var style = LayerTextStyle()
        style.content = content
        if let fontName = options.flags["font"] { style.fontName = fontName }
        if let size = options.flags["size"], let value = Double(size) { style.fontSize = CGFloat(value) }
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
        let id = UUID()
        let name = options.flags["name"] ?? EditorLayerNaming.layerName(for: content)

        var origin = canvasCenterOrigin(content: content, style: style, box: style.boxSize,
                                        width: snapshot.manifest.width, height: snapshot.manifest.height,
                                        explicit: options.flags["origin"])
        let size = style.boxSize ?? CGSize(width: image.width, height: image.height)
        if options.flags["box"] != nil { origin = parseOrigin(options.flags["origin"]) ?? origin }
        origin.x = origin.x.rounded(); origin.y = origin.y.rounded()

        let transform = LayerTransform(origin: origin, size: size)
        let record = ProjectLayerRecord(id: id, name: name, isVisible: true, transform: transform,
                                        imageFile: "\(id.uuidString).png", text: style)
        var layers = snapshot.manifest.layers
        layers.append(record)
        let manifest = manifestWith(snapshot.manifest, activeLayerID: id, layers: layers)
        var images = snapshot.images
        images[id] = ImportedImage(image: image, thumbnail: image, name: name)
        let updated = ProjectSnapshot(manifest: manifest, images: images, masks: snapshot.masks)

        // ProjectStore.save validates the whole package and writes it with the
        // app's own atomic package replacement.
        try await ProjectStore.shared.save(updated, to: url)

        if options.flags["json"] != nil {
            jsonOutput(["layer": id.uuidString, "name": name, "image": "\(id.uuidString).png",
                        "origin": "\(Int(origin.x)),\(Int(origin.y))",
                        "size": "\(Int(size.width))×\(Int(size.height))"])
        } else {
            print("added text layer \"\(name)\" \(id) at \(Int(origin.x)),\(Int(origin.y)) size \(Int(size.width))×\(Int(size.height))")
        }
    }

    static func parseOrigin(_ spec: String?) -> CGPoint? {
        guard let spec else { return nil }
        let parts = spec.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }

    static func canvasCenterOrigin(content: String, style: LayerTextStyle, box: CGSize?,
                                   width: Int, height: Int, explicit: String?) -> CGPoint {
        if let explicit = parseOrigin(explicit) { return explicit }
        let size = box ?? TextRasterizer.boxSize(style)
        return CGPoint(x: (CGFloat(width) - size.width) / 2, y: (CGFloat(height) - size.height) / 2)
    }
}

/// Headless copy of the text rendering statics from TypeTool.swift, operating
/// purely on `LayerTextStyle`. Keep in sync with the app.
enum TextRasterizer {
    static func image(_ style: LayerTextStyle) throws -> CGImage {
        guard style.isValid else { throw ProjectError.invalid }
        let string = attributedText(style)
        let padding = LayerTextStyle.padding
        let size = boxSize(style)
        let width = ceil(size.width), height = ceil(size.height)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= DocumentLimits.maxSideExtent, height <= DocumentLimits.maxSideExtent,
              width * height <= DocumentLimits.maxSurfaceExtent else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: Int(width), height: Int(height), mask: false)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let storage = NSTextStorage(attributedString: string)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width - 2 * padding),
                                                     height: max(1, height - 2 * padding)))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let glyphs = layout.glyphRange(for: container)
        layout.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: padding, y: padding))
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    static func boxSize(_ style: LayerTextStyle) -> CGSize {
        if let boxSize = style.boxSize { return boxSize }
        let string = attributedText(style)
        let padding = LayerTextStyle.padding
        let measured = string.boundingRect(with: CGSize(width: 100_000, height: 100_000),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading])
        let line = ceil(style.lineHeight)
        return CGSize(width: max(16, ceil(measured.width + padding * 2 + style.fontSize * 0.1)),
                      height: max(16, ceil(max(measured.height, line) + padding * 2)))
    }

    static func attributedText(_ style: LayerTextStyle) -> NSMutableAttributedString {
        let string = NSMutableAttributedString(string: style.content, attributes: attributes(style))
        for run in style.fontRuns ?? [] where EditorText.containsTextRun(run.location, run.length, in: string.length) {
            let font = NSFont(name: run.fontName, size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize)
            string.addAttribute(.font, value: font, range: NSRange(location: run.location, length: run.length))
        }
        for run in style.colorRuns ?? [] where EditorText.containsTextRun(run.location, run.length, in: string.length) {
            string.addAttribute(.foregroundColor,
                                value: NSColor(srgbRed: run.red, green: run.green, blue: run.blue, alpha: 1),
                                range: NSRange(location: run.location, length: run.length))
        }
        return string
    }

    static func attributes(_ style: LayerTextStyle) -> [NSAttributedString.Key: Any] {
        // Mirrors TypeTool.textAttributes exactly: leading is the whole line
        // height (min=max), word wrapping, kern, font, color.
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment == .left ? .left : style.alignment == .center ? .center : .right
        paragraph.minimumLineHeight = style.lineHeight
        paragraph.maximumLineHeight = style.lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        return [.font: NSFont(name: style.fontName, size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize),
                .foregroundColor: NSColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1),
                .paragraphStyle: paragraph, .kern: style.tracking]
    }
}

/// The one EditorSession helper the renderer needs, kept name-compatible.
enum EditorText {
    static func containsTextRun(_ location: Int, _ length: Int, in total: Int) -> Bool {
        length > 0 && location >= 0 && location <= total - length
    }
}

enum EditorLayerNaming {
    static func layerName(for content: String) -> String {
        let flattened = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return flattened.isEmpty ? "Text" : String(flattened.prefix(40))
    }
}
