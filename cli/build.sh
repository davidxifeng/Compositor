#!/bin/bash
# Builds the `compositor` CLI from the app's own core sources.
#
#   ./cli/build.sh          -> build/compositor
#
# Compiles every app source except the GUI entry points (CompositorApp,
# ContentView, CompositorApplicationDelegate — the last one is the only
# Sparkle dependent). The bridging header makes the C pixel kernels visible
# to Swift, exactly as in the app target. AppKit/SwiftUI code compiles and
# links fine in a command-line tool; views simply never get instantiated.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT/build"
BIN="$OUT_DIR/compositor"
mkdir -p "$OUT_DIR"

cd "$ROOT"

echo "== C pixel kernels =="
C_OBJECTS=()
for c in Compositor/Rendering/*.c; do
  obj="$OUT_DIR/$(basename "${c%.c}").o"
  clang -O2 -c "$c" -o "$obj"
  C_OBJECTS+=("$obj")
done

echo "== Swift =="
SOURCES=()
while IFS= read -r f; do
  case "$(basename "$f")" in
    CompositorApp.swift|ContentView.swift|CompositorApplicationDelegate.swift) continue ;;
  esac
  case "$f" in
    */UI/*|*/Rendering/InlineTextEditor.swift|*/Rendering/EditorCanvas.swift) continue ;;
    */IO/ProjectController.swift|*/IO/ProjectController+ExternalChanges.swift|*/IO/ImageFileDrop.swift) continue ;;
    */Document/ProjectWorkspace.swift) continue ;;
  esac
  SOURCES+=("$f")
done < <(find Compositor -name '*.swift' | sort)
SOURCES+=("$ROOT/cli/CliValidate.swift" "$ROOT/cli/CliEdit.swift" "$ROOT/cli/CliRender.swift" "$ROOT/cli/CliText.swift" "$ROOT/cli/main.swift")

xcrun swiftc \
  -swift-version 5 \
  -default-isolation MainActor \
  -enable-upcoming-feature DisableOutwardActorInference \
  -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
  -enable-upcoming-feature InferIsolatedConformances \
  -enable-upcoming-feature InferSendableFromCaptures \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature MemberImportVisibility \
  -import-objc-header "$ROOT/Compositor/Compositor-Bridging-Header.h" \
  -I "$ROOT/Compositor" \
  -O \
  -o "$BIN" \
  "${C_OBJECTS[@]}" \
  "${SOURCES[@]}"

echo "built: $BIN"
