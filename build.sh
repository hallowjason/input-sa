#!/bin/bash
# Build a native Input-sa bundle; keep release and local outputs separate.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/InputSa"
BUILD_DIR="$SCRIPT_DIR/build"
INCLUDE_LOCAL_MODELS=1
REQUIRE_WHISPER=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) [ "$#" -ge 2 ] || { echo "--output requires a directory" >&2; exit 2; }; BUILD_DIR="$2"; shift 2 ;;
        --without-local-models) INCLUDE_LOCAL_MODELS=0; shift ;;
        --require-whisper) REQUIRE_WHISPER=1; shift ;;
        --help) echo "Usage: bash build.sh [--output DIR] [--without-local-models] [--require-whisper]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
mkdir -p "$BUILD_DIR"
BUILD_DIR="$(cd "$BUILD_DIR" && pwd)"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/.inputsa-build.XXXXXX")"
APP_BUNDLE="$STAGING_DIR/Input-sa.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/Input-sa"
RESOURCES="$APP_BUNDLE/Contents/Resources"
FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"
DESTINATION="$BUILD_DIR/Input-sa.app"
cleanup() {
    if [ -d "$STAGING_DIR/previous.app" ] && [ ! -e "$DESTINATION" ]; then
        mv "$STAGING_DIR/previous.app" "$DESTINATION"
    fi
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT
# FoundationModels macros require the full Xcode SDK when available.
SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null \
    || xcrun --show-sdk-path 2>/dev/null \
    || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
TARGET="$(uname -m)-apple-macosx12.0"
SHERPA_DIR="$SCRIPT_DIR/vendor/sherpa"
WHISPER_DIR="$SCRIPT_DIR/vendor/whisper"
if [ "$REQUIRE_WHISPER" = 1 ] && [ ! -f "$WHISPER_DIR/whisper-server" ]; then
    echo "Missing Whisper runtime. Run bash tools/prepare-whisper-runtime.sh first." >&2
    exit 1
fi
# Only production Swift lives under InputSa; tests and bindings are outside it.
SOURCES=()
while IFS= read -r -d '' source_file; do
    SOURCES+=("$source_file")
done < <(find "$SRC" -type f -name '*.swift' -print0)
SOURCES+=("$SHERPA_DIR/swift/SherpaOnnx.swift")
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$RESOURCES" "$FRAMEWORKS"
echo "Building Input-sa ($TARGET) → $BUILD_DIR"
swiftc \
    -sdk "$SDK" -target "$TARGET" -swift-version 5 -module-name InputSa -Onone \
    -framework AppKit -framework Carbon -framework AVFoundation -framework CoreAudio \
    -framework Security -framework ApplicationServices \
    -import-objc-header "$SHERPA_DIR/swift/SherpaOnnx-Bridging-Header.h" \
    -I "$SHERPA_DIR/include" -L "$SHERPA_DIR/lib" -lsherpa-onnx-c-api \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -Xfrontend -disable-reflection-metadata \
    -o "$EXECUTABLE" "${SOURCES[@]}"
cp "$SHERPA_DIR/lib/libsherpa-onnx-c-api.dylib" "$FRAMEWORKS/"
cp "$SHERPA_DIR/lib/libonnxruntime.1.24.4.dylib" "$FRAMEWORKS/"
for resource_name in opencc dojo hud; do
    [ ! -d "$SRC/Resources/$resource_name" ] || cp -R "$SRC/Resources/$resource_name" "$RESOURCES/$resource_name"
done
if [ "$INCLUDE_LOCAL_MODELS" = 1 ]; then
    cp -R "$SRC/Resources/model" "$RESOURCES/model"
fi
# This optional runtime is arm64/macOS 14; Swift gates it separately. The large
# downloadable model belongs in Application Support, never this signed bundle.
if [ -f "$WHISPER_DIR/whisper-server" ]; then
    mkdir -p "$RESOURCES/whisper"
    for runtime_name in whisper-server whisper-cli; do
        if [ -f "$WHISPER_DIR/$runtime_name" ]; then
            cp "$WHISPER_DIR/$runtime_name" "$RESOURCES/whisper/"
            chmod 755 "$RESOURCES/whisper/$runtime_name"
        fi
    done
    for notice in "$WHISPER_DIR"/LICENSE*.txt "$WHISPER_DIR"/VERSION.txt; do
        [ ! -f "$notice" ] || cp "$notice" "$RESOURCES/whisper/"
    done
    # Recomputed after signing; do not copy development paths from vendor's file.
    (cd "$RESOURCES/whisper" && shasum -a 256 whisper-server) > "$RESOURCES/whisper/SHA256SUMS.txt"
    if [ -f "$RESOURCES/whisper/whisper-cli" ]; then
        (cd "$RESOURCES/whisper" && shasum -a 256 whisper-cli) >> "$RESOURCES/whisper/SHA256SUMS.txt"
    fi
fi
cp "$SRC/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$SRC/Resources/inputsa-menu@2x.png" "$RESOURCES/"
printf 'APPLINSA' > "$APP_BUNDLE/Contents/PkgInfo"
[ ! -e "$DESTINATION" ] || mv "$DESTINATION" "$STAGING_DIR/previous.app"
mv "$APP_BUNDLE" "$DESTINATION"
echo "Built: $DESTINATION"
