#!/bin/bash
# build.sh — Compiles Input-sa and packages it as a .app bundle
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/InputSa"
BUILD_DIR="$SCRIPT_DIR/build"
APP_NAME="Input-sa"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
RESOURCES="$APP_BUNDLE/Contents/Resources"

SDK=$(xcrun --show-sdk-path 2>/dev/null || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
ARCH=$(uname -m)
TARGET="$ARCH-apple-macosx12.0"

# sherpa-onnx (local Paraformer transcription)
SHERPA_DIR="$SCRIPT_DIR/vendor/sherpa"
SHERPA_INCLUDE="$SHERPA_DIR/include"
SHERPA_LIB="$SHERPA_DIR/lib"
SHERPA_BRIDGE="$SHERPA_DIR/swift/SherpaOnnx-Bridging-Header.h"
FRAMEWORKS="$APP_BUNDLE/Contents/Frameworks"

echo "🔨 Building Input-sa..."
echo "   SDK: $SDK"
echo "   Target: $TARGET"

# Collect all Swift source files (Bopomofo/IME removed — voice + polish only)
SOURCES=(
    "$SRC/App/main.swift"
    "$SRC/App/AppDelegate.swift"
    "$SRC/InputMethod/InputController.swift"
    "$SRC/Learning/UserStyleModel.swift"
    "$SRC/AIServices/TranscriptionMode.swift"
    "$SRC/AIServices/VoiceServiceProtocol.swift"
    "$SRC/AIServices/APIKeyStore.swift"
    "$SRC/AIServices/GroqVoiceService.swift"
    "$SRC/AIServices/GoogleVoiceService.swift"
    "$SRC/AIServices/SherpaVoiceService.swift"
    "$SRC/AIServices/OpenCCConverter.swift"
    "$SRC/AIServices/DojoCorrectionTable.swift"
    "$SRC/AIServices/GeminiPolishService.swift"
    "$SCRIPT_DIR/vendor/sherpa/swift/SherpaOnnx.swift"
    "$SRC/UI/PixelGuanyinRenderer.swift"
    "$SRC/UI/HUDCharacter.swift"
    "$SRC/UI/VoiceHUDController.swift"
    "$SRC/UI/PolishPreviewController.swift"
    "$SRC/Preferences/ShortcutRecorderView.swift"
    "$SRC/Preferences/PreferencesWindowController.swift"
)

# Create bundle structure
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$RESOURCES"

# Compile
swiftc \
    -sdk "$SDK" \
    -target "$TARGET" \
    -swift-version 5 \
    -module-name InputSa \
    -Onone \
    -framework AppKit \
    -framework Carbon \
    -framework AVFoundation \
    -framework Security \
    -framework ApplicationServices \
    -import-objc-header "$SHERPA_BRIDGE" \
    -I "$SHERPA_INCLUDE" \
    -L "$SHERPA_LIB" -lsherpa-onnx-c-api \
    -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
    -Xfrontend -disable-reflection-metadata \
    -o "$EXECUTABLE" \
    "${SOURCES[@]}" 2>&1

echo "✅ Compiled: $EXECUTABLE"

# Bundle sherpa dylibs into Contents/Frameworks (rpath = @executable_path/../Frameworks)
mkdir -p "$FRAMEWORKS"
cp "$SHERPA_LIB/libsherpa-onnx-c-api.dylib"     "$FRAMEWORKS/"
cp "$SHERPA_LIB/libonnxruntime.1.24.4.dylib"    "$FRAMEWORKS/"
echo "✅ Bundled sherpa dylibs → $FRAMEWORKS"

# Bundle local model + opencc dictionary (subdirectories preserved for Bundle lookup)
# rm first: `cp -R dir existing-dir` nests dir INSIDE the target on rebuilds
rm -rf "$RESOURCES/model" "$RESOURCES/opencc" "$RESOURCES/dojo" "$RESOURCES/hud"
cp -R "$SRC/Resources/model"  "$RESOURCES/model"
cp -R "$SRC/Resources/opencc" "$RESOURCES/opencc"
cp -R "$SRC/Resources/dojo"   "$RESOURCES/dojo"
[ -d "$SRC/Resources/hud" ] && cp -R "$SRC/Resources/hud" "$RESOURCES/hud"
echo "✅ Bundled model/ + opencc/ + dojo/ + hud/ → $RESOURCES"

# Copy resources
cp "$SRC/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# PkgInfo is required by macOS for app bundle validation
printf 'APPLINSA' > "$APP_BUNDLE/Contents/PkgInfo"

# Generate menu icon using pure Python (no external dependencies)
# Creates a valid 16x16 RGBA PNG then converts to TIFF using sips
ICON_PNG="$RESOURCES/inputsa-menu.png"
ICON_TIFF="$RESOURCES/inputsa-menu.tiff"

python3 - "$ICON_PNG" << 'PYEOF'
import sys, struct, zlib

output_png = sys.argv[1]

# 16x16 pixel pattern for the menu icon (菩薩 silhouette)
# Row 0 = top; 1 = dark pixel, 0 = transparent
rows = [
    0b0000011110000000,
    0b0000100001000000,
    0b0001000000100000,
    0b0001011010100000,
    0b0001000000100000,
    0b0000111111000000,
    0b0000010010000000,
    0b0000010010000000,
    0b0000111111000000,
    0b0001000000100000,
    0b0001000000100000,
    0b0000100001000000,
    0b0000011110000000,
    0b0000001100000000,
    0b0000001100000000,
    0b0000001100000000,
]

W, H = 16, 16

# Build raw PNG image data (RGBA, filter byte 0 per scanline)
raw = b''
for row in rows:
    raw += b'\x00'  # filter: None
    for x in range(W):
        if row & (1 << (15 - x)):
            raw += bytes([44, 44, 44, 255])   # dark grey, opaque
        else:
            raw += bytes([0, 0, 0, 0])         # transparent

compressed = zlib.compress(raw, 9)

def chunk(tag, data):
    crc = zlib.crc32(tag + data) & 0xFFFFFFFF
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)

png  = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0))
png += chunk(b'IDAT', compressed)
png += chunk(b'IEND', b'')

with open(output_png, 'wb') as f:
    f.write(png)
print(f'PNG icon generated: {output_png}')
PYEOF

# Convert PNG → TIFF using macOS built-in sips (no Xcode or Pillow needed)
if [ -f "$ICON_PNG" ]; then
    sips -s format tiff "$ICON_PNG" --out "$ICON_TIFF" > /dev/null 2>&1
    rm -f "$ICON_PNG"
    echo "✅ Menu icon: $ICON_TIFF"
else
    echo "⚠️  Icon generation failed — skipping (input method will work without it)"
fi

echo "📦 App bundle created: $APP_BUNDLE"
echo ""
echo "Run ./install.sh to install."
