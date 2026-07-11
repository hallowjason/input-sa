#!/bin/bash
# register.sh — Run this AFTER confirming Gatekeeper disable in System Settings
# Usage: bash register.sh

APP="$HOME/Library/Input Methods/Input-sa.app"

echo "🔍 Checking Gatekeeper status..."
GK=$(spctl --status 2>&1)
echo "   $GK"

if echo "$GK" | grep -q "enabled"; then
    echo ""
    echo "⚠️  Gatekeeper is still enabled."
    echo "   Please go to: System Settings → Privacy & Security"
    echo "   Find the security section and click to allow 'any source' / confirm disabling."
    echo "   Then run this script again."
    echo ""
    exit 1
fi

echo "✓ Gatekeeper disabled"
echo ""

# Kill any stale instances
echo "♻️  Killing old instances..."
pkill -f "Input-sa" 2>/dev/null || true
sleep 0.5

# Re-sign the bundle cleanly
echo "✍️  Re-signing bundle..."
codesign --force --deep --sign - "$APP" 2>&1

# Verify signature passes now
echo "🔍 Verifying signature..."
spctl --assess "$APP" 2>&1 && echo "   ✓ Accepted" || echo "   ✓ Gatekeeper disabled — proceeding"

# Register with TIS
echo "📝 Registering with TIS..."
/usr/bin/swift - << 'SWIFT'
import Carbon
import Foundation
let path = NSHomeDirectory() + "/Library/Input Methods/Input-sa.app"
let url = URL(fileURLWithPath: path) as CFURL
let status = TISRegisterInputSource(url)
print("   TIS register: \(status == noErr ? "OK ✓" : "error \(status)")")

sleep(1)

// Verify it's in the list
let filterDict: [String: Any] = [kTISPropertyBundleID as String: "com.inputsa.inputmethod"]
if let sources = TISCreateInputSourceList(filterDict as CFDictionary, true)?.takeRetainedValue() as? [TISInputSource],
   !sources.isEmpty {
    print("   ✓ Input-sa found in TIS database!")
} else {
    print("   ⚠ Not yet in TIS list — a logout/login may be needed")
}
SWIFT

# Restart input method services
echo "🔄 Restarting services..."
killall TextInputMenuAgent 2>/dev/null || true
killall TextInputSwitcher 2>/dev/null || true
killall cfprefsd 2>/dev/null || true
sleep 1

echo ""
echo "✅ Done! Now:"
echo "   1. System Settings → Keyboard → Input Sources → +"
echo "   2. Select '繁體中文' (Traditional Chinese)"
echo "   3. Find and add 'Input-sa'"
echo ""
echo "If Input-sa doesn't appear, log out and back in, then try again."
