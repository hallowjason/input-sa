#!/bin/bash
# install.sh — Plan B: Build and install Input-sa as a regular macOS app
# No IMKit / TIS registration required. Uses CGEventTap + AXUIElement.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Input-sa"
BUILD_APP="$SCRIPT_DIR/build/$APP_NAME.app"
INSTALL_DIR="$HOME/Applications"

# 1. Build
echo "🔨 Building..."
bash "$SCRIPT_DIR/build.sh"

# 2. Kill any running instance
echo "♻️  Stopping old instance..."
pkill -f "Input-sa" 2>/dev/null || true
sleep 0.5

# 3. Fix PkgInfo
printf 'APPLINSA' > "$BUILD_APP/Contents/PkgInfo"

# 4. Sign (as current user — private key is in user keychain)
# Inside-out: sign bundled sherpa dylibs FIRST, then the app. --deep alone can
# miss/mis-order nested Mach-O signing, so the Frameworks dylibs are signed explicitly.
echo "✍️  Signing..."
DEV_CERT=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
SIGN_ID="-"
[ -n "$DEV_CERT" ] && SIGN_ID="$DEV_CERT"
echo "   Using identity: $SIGN_ID"

# 4a. Sign each bundled dylib (no entitlements — libraries don't carry app entitlements)
FRAMEWORKS_DIR="$BUILD_APP/Contents/Frameworks"
if [ -d "$FRAMEWORKS_DIR" ]; then
    for DYLIB in "$FRAMEWORKS_DIR"/*.dylib; do
        [ -e "$DYLIB" ] || continue
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$DYLIB" 2>&1
        echo "   ✓ Signed $(basename "$DYLIB")"
    done
fi

# 4b. Sign the app bundle (--deep re-verifies nested code, entitlements applied to main exe)
codesign --force --deep --sign "$SIGN_ID" \
    --options runtime \
    --entitlements "$SCRIPT_DIR/InputSa/Resources/InputSa.entitlements" \
    "$BUILD_APP" 2>&1

# Verify signature
if codesign -v "$BUILD_APP" 2>/dev/null; then
    echo "   ✓ Signature valid"
else
    echo "   ⚠️  Signature issue, continuing anyway"
fi

# 5. Create install directory and remove old install
mkdir -p "$INSTALL_DIR"
echo "🗑  Removing old installation..."
rm -rf "$INSTALL_DIR/$APP_NAME.app"
# Also clean up old IMKit installs if present
sudo rm -rf "/Library/Input Methods/$APP_NAME.app" 2>/dev/null || true
rm -rf "$HOME/Library/Input Methods/$APP_NAME.app" 2>/dev/null || true

# 6. Install
echo "📥 Installing to $INSTALL_DIR/$APP_NAME.app ..."
cp -R "$BUILD_APP" "$INSTALL_DIR/$APP_NAME.app"
chmod -R 755 "$INSTALL_DIR/$APP_NAME.app"

# 7. Remove quarantine xattr
xattr -rd com.apple.quarantine "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true

# 7.5 Reset TCC microphone entry so macOS re-prompts on next launch.
# Opt-in only (./install.sh --reset-mic) — the signing identity (team id
# 5X94884GN9) is stable across rebuilds, so the mic grant survives reinstalls
# and resetting it every time just makes you re-approve for no reason.
if [ "$1" = "--reset-mic" ]; then
    echo "🔐 Resetting microphone TCC permission (so macOS re-prompts)..."
    tccutil reset Microphone com.inputsa.inputmethod 2>/dev/null || true
fi

# 8. Register with LaunchServices so Spotlight finds it
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
  "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true
echo "   LS registered at: $INSTALL_DIR/$APP_NAME.app"

# 9. Launch (will prompt for Accessibility permission on first run)
echo "🚀 Launching Input-sa..."
open "$INSTALL_DIR/$APP_NAME.app"

echo ""
echo "✅ 安裝完成！"
echo ""
echo "接下來的步驟："
echo ""
echo "  1. 授予輔助使用功能權限（必須）："
echo "     系統設定 → 隱私權與安全性 → 輔助使用功能"
echo "     啟用 'Input-sa'"
echo ""
echo "  2. 加入登入項目（開機自動啟動）："
echo "     系統設定 → 一般 → 登入項目與延伸功能"
echo "     點擊 + 並選擇：$INSTALL_DIR/$APP_NAME.app"
echo ""
echo "  3. 開始使用："
echo "     選單列會出現 🎙 圖示"
echo ""
echo "  快捷鍵："
echo "     語音轉錄：按住右 Option（放開後自動送出）"
echo "     文字潤飾：Option+P（先在任意 App 選取文字，再按）"
echo "     偏好設定：Ctrl+Option+P（隨時開啟），或點選單列 🎙"
