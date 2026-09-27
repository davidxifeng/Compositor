# compositor CLI

Headless command-line access to the Compositor app's own core: validation,
render-flattening and text-layer creation all run through the exact code paths
the app uses — `ProjectStore` (load/validate/atomic save), `ImageExporter`
(the app's PNG/JPEG export pipeline, including adjustment layers, layer
effects, folder masks, clipping masks and all 24 blend modes) and the text
layout from `TypeTool`.

No app-side changes are needed to run it; it compiles the app sources
directly.

## Build

```sh
./cli/build.sh        # → build/compositor
```

## Commands

### Pipeline

```sh
compositor validate <pkg.comp> [--json]
#   ProjectStore verdict + a per-rule diagnostic pass that reports EVERY
#   violation. The app's file-watcher path fails silently; this doesn't.

compositor render <pkg.comp> --out out.png [--layer <uuid|name>]
#                  [--format png|jpeg] [--quality 0.85] [--max-size <px>] [--json]
#   Flatten through the real render pipeline. --layer hides everything except
#   that layer (its ancestors stay visible). --max-size scales the longest
#   side down for cheap previews.

compositor text <pkg.comp> --content "标题" [--name ...] [--font PostScriptName]
#                [--size 96] [--color #RRGGBB] [--align left|center|right]
#                [--tracking 0] [--leading 0] [--origin x,y] [--box w,h] [--json]
#   Adds a text layer: renders the pixels AND stores `text` metadata, so the
#   layer stays editable as real text in the app. Saves through
#   ProjectStore.save (full validation + atomic package replacement).

compositor layers <pkg> [--json]
#   Layer tree, bottom → top: ids, kinds (image/folder/adjustment/text),
#   visibility, effective opacity, blend, transforms, masks, clipping.

compositor adjustments [kind] [--json]
#   List the 12 adjustment kinds, or print the complete default settings
#   JSON of one kind — exactly what a project file stores for a new
#   adjustment layer. Use it to build `adjustment` payloads.
```

### Editing

```sh
compositor set <pkg> --layer <sel> [--name s] [--visible on|off] [--opacity f]
#              [--blend m] [--origin x,y] [--size w,h] [--rotation d]
#              [--flip-x on|off] [--flip-y on|off] [--sampling s]
#   Change fields; omitted fields are left alone.

compositor move <pkg> --layer <sel> (--above <sel> | --below <sel> | --top |
#               --bottom | --index n) [--parent <sel>|root]
#   Move a layer; a folder carries its subtree. --parent reparents.

compositor remove <pkg> --layer <sel>
#   Delete a layer; a folder's contents go with it.

compositor duplicate <pkg> --layer <sel> [--name s] [--offset dx,dy]
#   Copy a layer with pixels and mask, placed above the original.

compositor group <pkg> --layers <sel,sel,...> [--name s]
#   Put layers into a new folder (same parent required).

compositor mask <pkg> --layer <sel> (--image <file> [--invert] | --clear | --enable on|off)
#   Attach a grayscale mask (converted to 8-bit gray at the layer's pixel
#   size), invert it, toggle it, or clear it.

compositor import <pkg> --image <file> [--fit none|contain|cover|stretch]
#                 [--origin x,y] [--size w,h] [--opacity f] [--blend m] [--name s]
#   Import an image file as the top layer.

compositor canvas <pkg> --size <w,h> [--anchor center|top-left|top|top-right|
#                 left|right|bottom-left|bottom|bottom-right]
#   Change the canvas size without resampling layers.

compositor image-size <pkg> --size <w,h> [--resolution ppi] [--sampling s]
#   Resample the whole document — layers, masks and guides included.
```

`--layer` selectors accept a UUID or a layer name (case-insensitive when
unique; ambiguous names list their UUIDs).

Exit codes: `0` ok · `1` rejected/failed · `2` usage.

## How the build works

`build.sh` compiles the app's own sources with `swiftc
-import-objc-header Compositor/Compositor-Bridging-Header.h` (so the C pixel
kernels are visible to Swift, same as the app target) and mirrors the app
build settings (`-swift-version 5 -default-isolation MainActor
-enable-upcoming-feature ApproachableConcurrency`).

Excluded from the compile (GUI-only plumbing the CLI never instantiates):

- `CompositorApp.swift`, `ContentView.swift`, `CompositorApplicationDelegate.swift` (the only Sparkle dependent)
- `UI/` (all sheets, panels and controls)
- `Rendering/EditorCanvas.swift`, `Rendering/InlineTextEditor.swift` (AppKit canvas views)
- `IO/ProjectController.swift`, `IO/ProjectController+ExternalChanges.swift`, `IO/ImageFileDrop.swift` (window/session orchestration)
- `Document/ProjectWorkspace.swift`

One small source move was made for clean layering: `PSDConversionRequest`
moved from `UI/PSDConversionSheet.swift` to `IO/PSD/PSDTypes.swift` — it is a
value type used by core `EditorSession`, not a view.

## Known mirror

`cli/CliText.swift` re-implements `EditorSession.textImage` /
`textBoxSize` / `attributedText` (~45 lines of TextKit) because those statics
live on the UI-coupled `EditorSession`. If text layout changes in
`TypeTool.swift`, update the mirror. Everything else is the app's code
unmodified.

## Latency notes

`ProjectStore` and `ImageExporter` are actors, so commands are `async`; the
first launch has no model-load cost (pure CPU/CoreGraphics/Metal on demand).
Rendering a 1920×1080 project with 6 layers ≈ 1s cold.
