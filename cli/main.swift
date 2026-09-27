// compositor — headless CLI over the app's own core (ProjectStore, ImageExporter, TextTool).
//
//   compositor validate <pkg.comp> [--json]
//   compositor render  <pkg.comp> --out <file> [--layer <uuid|name>] [--format png|jpeg] [--quality 0.85] [--json]
//   compositor text    <pkg.comp> --content <string> [options] [--json]
//
// Everything runs through the same ProjectStore validation and the same
// render/encode pipeline the app uses; nothing here reimplements the format.

import AppKit
import Foundation
import UniformTypeIdentifiers

let args = Array(CommandLine.arguments.dropFirst())

func usage() -> Never {
    print("""
    usage: compositor <command> [options]

    commands:
      validate <pkg> [--json]
          Run the full ProjectStore validation plus a per-rule diagnostic pass
          that reports every violation (the app itself stops at the first).

      render <pkg> --out <file> [--layer <uuid|name>] [--format png|jpeg]
                     [--quality 0.0-1.0] [--max-size <px>] [--json]
          Flatten through the app's render pipeline. --layer hides everything
          except that layer (its ancestors stay visible). --max-size scales the
          longest output side down, for cheap previews.

      layers <pkg> [--json]
          Layer tree, bottom → top, with ids, kinds, visibility and transforms.

      adjustments [kind] [--json]
          List adjustment kinds, or print the full default settings of one —
          the exact JSON a project file stores for a new adjustment layer.

      set <pkg> --layer <sel> [--name s] [--visible on|off] [--opacity f]
          [--blend m] [--origin x,y] [--size w,h] [--rotation d]
          [--flip-x on|off] [--flip-y on|off] [--sampling s]
          [--content s] [--font <postscript-name>] [--font-size px] [--color #RRGGBB]
          [--align left|center|right] [--tracking f] [--leading f] [--box w,h]
          Change fields; omitted fields are left alone. Text fields re-render a
          text layer's pixels (--size stays the transform box; unknown options
          are rejected).

      move <pkg> --layer <sel> (--above <sel> | --below <sel> | --top | --bottom
           | --index n) [--parent <sel>|root]
          Move a layer (a folder carries its subtree) in the stack. Positions
          are z-order terms, matching the layers listing: --top is the topmost
          layer, --above <sel> sits directly over <sel>, --index counts from
          the bottom (0 = bottom).

      remove <pkg> --layer <sel>
          Delete a layer; deleting a folder deletes its contents.

      duplicate <pkg> --layer <sel> [--name s] [--offset dx,dy]
          Copy a layer with pixels and mask, placed above the original.

      group <pkg> --layers <sel,sel,...> [--name s]
          Put layers into a new folder.

      mask <pkg> --layer <sel> (--image <file> [--invert] | --clear | --enable on|off)
          Attach a grayscale mask (converted to 8-bit gray at the layer's
          pixel size), invert it, toggle it, or clear it.

      import <pkg> --image <file> [--fit none|contain|cover|stretch] [--origin x,y]
             [--size w,h] [--opacity f] [--blend m] [--name s]
          Import an image file as the top layer.

      canvas <pkg> --size <w,h> [--anchor center|top-left|top|top-right|left|right|
             bottom-left|bottom|bottom-right]
          Change the canvas size without resampling layers.

      image-size <pkg> --size <w,h> [--resolution ppi] [--sampling s]
          Resample the whole document, layers and masks included.

      text <pkg> --content <string> [--name s] [--font <postscript-name>]
           [--size px] [--color #RRGGBB] [--align left|center|right]
           [--tracking f] [--leading f] [--origin x,y] [--box w,h] [--json]
          Add an editable text layer.

    --layer selectors accept a UUID or a layer name (case-insensitive when unique).
    exit codes: 0 ok · 1 rejected or failed · 2 usage error
    """)
    exit(2)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("compositor: \(message)\n".utf8))
    exit(1)
}

struct Options {
    var flags: [String: String] = [:]
    var list: [String] = []

    init(_ args: [String]) {
        var i = 0
        while i < args.count {
            let a = args[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                    flags[key] = args[i + 1]
                    i += 2
                } else {
                    flags[key] = "true"
                    i += 1
                }
            } else {
                list.append(a)
                i += 1
            }
        }
    }
}

func parseHexColor(_ hex: String) -> (CGFloat, CGFloat, CGFloat)? {
    var text = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
    if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
    guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
    return (CGFloat((value >> 16) & 0xFF) / 255, CGFloat((value >> 8) & 0xFF) / 255, CGFloat(value & 0xFF) / 255)
}

func atomicWrite(_ data: Data, to url: URL) throws {
    let tmp = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString.prefix(6)).tmp")
    try data.write(to: tmp)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
}

/// ProjectManifest's identity fields are `let`; rebuild it wholesale.
func manifestWith(_ m: ProjectManifest, activeLayerID: UUID?, layers: [ProjectLayerRecord]) -> ProjectManifest {
    ProjectManifest(format: m.format, version: m.version, colorSpace: m.colorSpace,
                    resolution: m.resolution, documentID: m.documentID, width: m.width,
                    height: m.height, activeLayerID: activeLayerID, layers: layers, guides: m.guides)
}

func jsonOutput(_ value: Any) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
}

guard let command = args.first else { usage() }
let rest = Array(args.dropFirst())

do {
    switch command {
    case "validate": try await ValidateCommand.run(rest)
    case "render": try await RenderCommand.run(rest)
    case "text": try await TextCommand.run(rest)
    case "layers": try await LayersCommand.run(rest)
    case "adjustments": try AdjustmentsCommand.run(rest)
    case "set": try await SetCommand.run(rest)
    case "move": try await MoveCommand.run(rest)
    case "remove": try await RemoveCommand.run(rest)
    case "duplicate": try await DuplicateCommand.run(rest)
    case "group": try await GroupCommand.run(rest)
    case "mask": try await MaskCommand.run(rest)
    case "import": try await ImportCommand.run(rest)
    case "canvas": try await CanvasCommand.run(rest)
    case "image-size": try await ImageSizeCommand.run(rest)
    case "help", "--help", "-h": usage()
    default: usage()
    }
} catch let error as LocalizedError {
    fail(error.errorDescription ?? String(describing: error))
} catch DecodingError.dataCorrupted(let context) {
    fail("manifest.json: \(context.debugDescription) \(context.codingPath.map(\.stringValue))")
} catch let error {
    fail(String(describing: error))
}
