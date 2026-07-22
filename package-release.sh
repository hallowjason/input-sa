#!/bin/bash
# package-release.sh — Builds Input-sa and packages it as a distributable .zip
# for GitHub Releases. Signs with the PERSISTENT "Input-sa Code Signing" cert
# (run tools/create-signing-cert.sh once to create it) so every release shares
# ONE fixed signature — macOS mic/accessibility grants then survive every update
# instead of breaking each version the way ad-hoc signing does. Falls back to
# ad-hoc only if that cert is missing. Either way the app is un-notarized, so
# recipients right-click → Open once on first install.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Input-sa"
BUILD_APP="$SCRIPT_DIR/build/$APP_NAME.app"
PLIST="$SCRIPT_DIR/InputSa/Resources/Info.plist"
SRC_MODEL_DIR="$SCRIPT_DIR/InputSa/Resources/model/sensevoice"
STASH_DIR="$SCRIPT_DIR/.release-model-stash"
SIGN_CERT_NAME="Input-sa Code Signing"

# 1. Temporarily stash any local .onnx model(s) so the release build never
#    bundles them (release stays cloud-only / Groq default). Restored at the
#    end regardless of success or failure — this machine's own local/offline
#    install is not affected.
STASHED=0
if ls "$SRC_MODEL_DIR"/*.onnx >/dev/null 2>&1; then
    echo "📤 Stashing local .onnx model(s) out of the source tree for this build..."
    mkdir -p "$STASH_DIR"
    mv "$SRC_MODEL_DIR"/*.onnx "$STASH_DIR/"
    STASHED=1
fi
restore_model() {
    if [ "$STASHED" = "1" ]; then
        mv "$STASH_DIR"/*.onnx "$SRC_MODEL_DIR/" 2>/dev/null || true
        rmdir "$STASH_DIR" 2>/dev/null || true
        echo "📥 Restored local .onnx model(s) to $SRC_MODEL_DIR"
    fi
}
trap restore_model EXIT

# 2. Build (with model stashed, so the bundled app is cloud-only)
echo "🔨 Building..."
bash "$SCRIPT_DIR/build.sh"

# 3. Guard: never ship the local model in a public release artifact
MODEL_DIR="$BUILD_APP/Contents/Resources/model/sensevoice"
if ls "$MODEL_DIR"/*.onnx >/dev/null 2>&1; then
    echo "❌ Refusing to package: found a bundled .onnx model in $MODEL_DIR"
    echo "   Release builds must stay cloud-only (Groq default)."
    exit 1
fi
echo "✅ No local model bundled — release stays cloud-only"

# 4. Fix PkgInfo
printf 'APPLINSA' > "$BUILD_APP/Contents/PkgInfo"

# 5. Sign with the persistent cert (stable signature = mic grants survive updates),
#    falling back to ad-hoc if it isn't installed yet.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_CERT_NAME"; then
    SIGN_ID="$SIGN_CERT_NAME"
    echo "✍️  Signing with persistent cert: $SIGN_ID"
else
    SIGN_ID="-"
    echo "⚠️  找不到「$SIGN_CERT_NAME」憑證，退回 ad-hoc 簽名（每版都會改變、他機麥克風授權會失效）。"
    echo "    先跑 ./tools/create-signing-cert.sh 建立固定憑證，再重跑本腳本，才能根治。"
fi
FRAMEWORKS_DIR="$BUILD_APP/Contents/Frameworks"
if [ -d "$FRAMEWORKS_DIR" ]; then
    for DYLIB in "$FRAMEWORKS_DIR"/*.dylib; do
        [ -e "$DYLIB" ] || continue
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$DYLIB" 2>&1
    done
fi
codesign --force --deep --sign "$SIGN_ID" \
    --options runtime \
    --entitlements "$SCRIPT_DIR/InputSa/Resources/InputSa.entitlements" \
    "$BUILD_APP" 2>&1

if codesign -v "$BUILD_APP" 2>/dev/null; then
    echo "   ✓ Ad-hoc signature valid"
else
    echo "❌ Signature verification failed"
    exit 1
fi

# 6. Read version and zip
VERSION=$(defaults read "$PLIST" CFBundleShortVersionString 2>/dev/null || echo "0.0.0")
ZIP_NAME="Input-sa-v${VERSION}.zip"
ZIP_PATH="$SCRIPT_DIR/$ZIP_NAME"

echo "📦 Zipping → $ZIP_NAME"
rm -f "$ZIP_PATH"
( cd "$SCRIPT_DIR/build" && zip -r -X -q "$ZIP_PATH" "$APP_NAME.app" )

echo ""
echo "✅ Done: $ZIP_PATH"
echo "   Next: gh release create v${VERSION} \"$ZIP_PATH\" --title \"Input-sa v${VERSION}\" --notes \"...\""
