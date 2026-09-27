// `compositor render` — flatten through the app's own ImageExporter, which is
// the exact pipeline the app's PNG/JPEG export uses (LiveMaskRenderer, layer
// effects, SeparableBlend, folder masks, adjustment layers).

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum RenderCommand {
    static func run(_ args: [String]) async throws {
        let options = Options(args)
        guard let path = options.list.first else {
            FileHandle.standardError.write(Data("render: pass a .comp package path\n".utf8))
            exit(2)
        }
        guard let out = options.flags["out"] else {
            FileHandle.standardError.write(Data("render: --out is required\n".utf8))
            exit(2)
        }
        let url = URL(fileURLWithPath: path)
        var snapshot = try await ProjectStore.shared.load(from: url)

        if let layerSelector = options.flags["layer"] {
            guard let id = resolveLayer(layerSelector, in: snapshot.manifest) else {
                fail("no layer matches \"\(layerSelector)\"")
            }
            snapshot = keepingVisibleOnly(id, in: snapshot)
        }

        let outURL = URL(fileURLWithPath: out)
        let wantsJPEG = (options.flags["format"] ?? outURL.pathExtension.lowercased()) == "jpeg"
            || options.flags["format"] == "jpg"

        var bytes: Data
        var width = 0, height = 0
        if wantsJPEG {
            let raster = try await ImageExporter.shared.render(snapshot)
            let quality = Double(options.flags["quality"] ?? "") ?? 0.85
            let result = try await ImageExporter.shared.jpeg(raster, options: JPEGOptions(quality: quality))
            bytes = result.data
            width = result.preview.width
            height = result.preview.height
        } else {
            bytes = try await ImageExporter.shared.pngData(snapshot)
            if let image = CGImageSourceCreateWithData(bytes as CFData, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] {
                width = props[kCGImagePropertyPixelWidth] as? Int ?? 0
                height = props[kCGImagePropertyPixelHeight] as? Int ?? 0
            }
            if let maxSpec = options.flags["max-size"], let max = Int(maxSpec) {
                bytes = try scale(bytes, longestSide: max)
                if let image = CGImageSourceCreateWithData(bytes as CFData, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] {
                    width = props[kCGImagePropertyPixelWidth] as? Int ?? width
                    height = props[kCGImagePropertyPixelHeight] as? Int ?? height
                }
            }
        }
        try atomicWrite(bytes, to: outURL)

        if options.flags["json"] != nil {
            jsonOutput(["out": outURL.path, "width": width, "height": height,
                        "bytes": bytes.count, "format": wantsJPEG ? "jpeg" : "png"])
        } else {
            print("\(outURL.path): \(width)×\(height), \(bytes.count) bytes")
        }
    }

    /// Downscale so the longest side is at most `max`, keeping DPI metadata.
    static func scale(_ png: Data, longestSide limit: Int) throws -> Data {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              max(width, height) > limit else { return png }
        let scale = CGFloat(limit) / CGFloat(max(width, height))
        let w = max(1, Int(CGFloat(width) * scale)), h = max(1, Int(CGFloat(height) * scale))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let interpolation = properties[kCGImagePropertyDPIWidth] as? Double else { return png }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let scaled = context.makeImage() else { return png }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return png
        }
        CGImageDestinationAddImage(destination, scaled, [
            kCGImagePropertyDPIWidth: interpolation, kCGImagePropertyDPIHeight: interpolation
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return png }
        return data as Data
    }

    /// Visibility override for --layer: the target and its ancestors stay
    /// visible, everything else (including unrelated folders) is hidden.
    static func keepingVisibleOnly(_ id: UUID, in snapshot: ProjectSnapshot) -> ProjectSnapshot {
        let manifest = snapshot.manifest
        let byID = Dictionary(uniqueKeysWithValues: manifest.layers.map { ($0.id, $0) })
        var keep = Set<UUID>()
        var cursor: UUID? = id
        while let current = cursor, keep.insert(current).inserted {
            cursor = byID[current]?.parentID
        }
        let updated = manifestWith(manifest, activeLayerID: manifest.activeLayerID,
                                   layers: manifest.layers.map { layer in
            var layer = layer
            layer.isVisible = keep.contains(layer.id)
            return layer
        })
        return ProjectSnapshot(manifest: updated, images: snapshot.images, masks: snapshot.masks)
    }
}
