#!/bin/bash
# Create a distributable zip without moving or deleting local source models.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_DIR="$SCRIPT_DIR/build/release"
BUILD_APP="$RELEASE_DIR/Input-sa.app"
SKIP_BUILD=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1; shift ;;
        --help) echo "Usage: bash package-release.sh [--skip-build]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
if [ "$SKIP_BUILD" = 0 ]; then
    bash "$SCRIPT_DIR/build.sh" --output "$RELEASE_DIR" --without-local-models --require-whisper
fi
[ -f "$BUILD_APP/Contents/Resources/whisper/whisper-server" ] || { echo "Release is missing the Whisper runtime." >&2; exit 1; }
if [ -n "$(find "$BUILD_APP/Contents/Resources" -type f \( -name '*.onnx' -o -name 'ggml-*.bin' \) -print -quit)" ]; then
    echo "Refusing to publish a bundled local speech model." >&2
    exit 1
fi
bash "$SCRIPT_DIR/tools/sign-app.sh" "$BUILD_APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD_APP/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version: $VERSION" >&2; exit 1; }
ZIP_NAME="Input-sa-v${VERSION}.zip"
ZIP_PATH="$SCRIPT_DIR/$ZIP_NAME"
PACKAGE_STAGE="$(mktemp -d "$RELEASE_DIR/.inputsa-package.XXXXXX")"
trap 'rm -rf "$PACKAGE_STAGE"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$BUILD_APP" "$PACKAGE_STAGE/$ZIP_NAME"
mkdir "$PACKAGE_STAGE/unpacked"
ditto -x -k "$PACKAGE_STAGE/$ZIP_NAME" "$PACKAGE_STAGE/unpacked"
codesign --verify --deep --strict --verbose=2 "$PACKAGE_STAGE/unpacked/Input-sa.app"
mv "$PACKAGE_STAGE/$ZIP_NAME" "$ZIP_PATH"
(cd "$SCRIPT_DIR" && shasum -a 256 "$ZIP_NAME") > "$PACKAGE_STAGE/checksum"
mv "$PACKAGE_STAGE/checksum" "$ZIP_PATH.sha256"
echo "Packaged and verified: $ZIP_PATH"
echo "Checksum: $ZIP_PATH.sha256"
echo "Local build and source models remain unchanged."
