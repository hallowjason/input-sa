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

# Prefer the Xcode SDK: the CommandLineTools SDK lacks the FoundationModels
# macro plugin (@Generable fails there with "plugin for module not found").
SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null \
    || xcrun --show-sdk-path 2>/dev/null \
    || echo "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk")
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
    "$SRC/AIServices/SystemAudioMute.swift"
    "$SRC/AIServices/GroqVoiceService.swift"
    "$SRC/AIServices/GoogleVoiceService.swift"
    "$SRC/AIServices/SherpaVoiceService.swift"
    "$SRC/AIServices/OpenCCConverter.swift"
    "$SRC/AIServices/DojoCorrectionTable.swift"
    "$SRC/AIServices/DojoSharedSync.swift"
    "$SRC/AIServices/GeminiPolishService.swift"
    "$SRC/AIServices/ApplePolishService.swift"
    "$SRC/AIServices/AudioLevelMeter.swift"
    "$SRC/AIServices/DojoVoiceParser.swift"
    "$SRC/AIServices/TranscriptNumberFormatter.swift"
    "$SRC/AIServices/UsageStatsStore.swift"
    "$SCRIPT_DIR/vendor/sherpa/swift/SherpaOnnx.swift"
    "$SRC/UI/PixelGuanyinRenderer.swift"
    "$SRC/UI/HUDCharacter.swift"
    "$SRC/UI/DesignTokens.swift"
    "$SRC/UI/PillSegmentedControl.swift"
    "$SRC/UI/CardListView.swift"
    "$SRC/UI/WaveformView.swift"
    "$SRC/UI/VoiceHUDController.swift"
    "$SRC/UI/PolishPreviewController.swift"
    "$SRC/Preferences/ShortcutRecorderView.swift"
    "$SRC/Preferences/EditorSheets.swift"
    "$SRC/Preferences/PreferencesSidebar.swift"
    "$SRC/Preferences/PreferencesWindowController.swift"
    "$SRC/Preferences/PreferencesVoiceServiceTab.swift"
    "$SRC/Preferences/PreferencesShortcutsTab.swift"
    "$SRC/Preferences/PreferencesModesTab.swift"
    "$SRC/Preferences/PreferencesDojoTab.swift"
    "$SRC/Preferences/PreferencesDashboardTab.swift"
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
    -framework CoreAudio \
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

# Menu bar icon (template image): geometric volume-bars mark, 72px @2x source
# in the repo. AppDelegate loads it via Bundle.main and sets isTemplate so it
# adapts to light/dark menu bars automatically. (Replaced the old generated
# 菩薩-silhouette tiff that nothing referenced.)
cp "$SRC/Resources/inputsa-menu@2x.png" "$RESOURCES/inputsa-menu@2x.png"
echo "✅ Menu icon: $RESOURCES/inputsa-menu@2x.png"

echo "📦 App bundle created: $APP_BUNDLE"
echo ""
echo "Run ./install.sh to install."
