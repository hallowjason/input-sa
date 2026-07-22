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
#
# Identity preference: the persistent "Input-sa Code Signing" cert first (same
# fixed signature the release uses → mic/accessibility grants survive updates,
# and local testing matches what friends get), then any Apple Development cert,
# then ad-hoc. Run tools/create-signing-cert.sh once to create the persistent cert.
echo "✍️  Signing..."
SIGN_CERT_NAME="Input-sa Code Signing"
DEV_CERT=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)"/\1/')
SIGN_ID="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_CERT_NAME"; then
    SIGN_ID="$SIGN_CERT_NAME"
elif [ -n "$DEV_CERT" ]; then
    SIGN_ID="$DEV_CERT"
fi
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

# 7.5 TCC hygiene. macOS ties the microphone grant to the app's code signature:
# with a real Apple Development identity the signature is stable across rebuilds
# and the grant survives, so resetting is opt-in (./install.sh --reset-mic).
# With the ad-hoc fallback ("-") every build produces a NEW signature — the old
# grant silently stops matching while the toggle in System Settings still shows
# ON, and recording captures nothing. Reset proactively in that case so macOS
# re-prompts instead of failing silently.
if [ "$SIGN_ID" = "-" ]; then
    echo ""
    echo "⚠️  找不到 Apple Development 憑證，已改用 ad-hoc 簽名。"
    echo "   ad-hoc 簽章每次重新安裝都會改變，舊的權限授權會失效"
    echo "   （系統設定裡開關看起來仍是開啟，實際上已對不上）。"
    echo "🔐 已自動重置麥克風授權——首次錄音時系統會重新詢問，請按「允許」。"
    tccutil reset Microphone com.inputsa.inputmethod 2>/dev/null || true
    echo "   若快捷鍵或聲波仍無反應：到「系統設定 › 隱私權與安全性」的"
    echo "   「輔助使用」與「輸入監控」，把 Input-sa 移除（－）再重新加入（＋），"
    echo "   不要只看開關顏色；或用選單列 🎙 →「系統診斷...」檢查。"
    echo ""
elif [ "$1" = "--reset-mic" ]; then
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
