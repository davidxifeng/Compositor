#!/bin/bash
# Builds a local arm64 Release app with an ad hoc signature. No certificate,
# notarization credentials, or DMG tooling are needed.
#
#   ./build.sh                 -> build/Compositor.app
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="Compositor"
BUILD_DIR="$PROJECT_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData-arm64"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP.app"
OUTPUT_APP="$BUILD_DIR/$APP.app"

mkdir -p "$BUILD_DIR"
xcodebuild build -quiet \
  -project "$PROJECT_DIR/$APP.xcodeproj" \
  -scheme "$APP" \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=

test -d "$BUILT_APP"
rm -rf "$OUTPUT_APP"
ditto "$BUILT_APP" "$OUTPUT_APP"
codesign --verify --deep --strict --verbose=2 "$OUTPUT_APP"
echo "Built ad hoc signed app: $OUTPUT_APP"
