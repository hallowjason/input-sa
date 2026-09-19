#!/bin/bash
# Sign inside-out with the existing persistent identity; never silently change it.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_BUNDLE="${1:-}"
if [ -z "$APP_BUNDLE" ] || [ ! -d "$APP_BUNDLE/Contents" ]; then
    echo "Usage: bash tools/sign-app.sh /path/to/Input-sa.app" >&2
    exit 2
fi
SIGN_CERT_NAME="Input-sa Code Signing"
SIGN_ID=$(security find-identity -v -p codesigning | awk -F '"' -v name="$SIGN_CERT_NAME" '$2 == name { split($1, fields, " "); print fields[2]; exit }')
if [ -z "$SIGN_ID" ]; then
    echo "Signing identity '$SIGN_CERT_NAME' is unavailable. Unlock the existing keychain; do not replace the certificate for an update." >&2
    exit 1
fi
echo "Signing with $SIGN_CERT_NAME ($SIGN_ID)"
if [ -d "$APP_BUNDLE/Contents/Frameworks" ]; then
    while IFS= read -r -d '' library; do
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$library"
    done < <(find "$APP_BUNDLE/Contents/Frameworks" -depth -type f -name '*.dylib' -print0)
fi
for executable in "$APP_BUNDLE/Contents/Resources/whisper/whisper-server" \
                  "$APP_BUNDLE/Contents/Resources/whisper/whisper-cli"; do
    if [ -f "$executable" ]; then
        codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$executable"
        codesign --verify --strict --verbose=2 "$executable"
    fi
done
if [ -f "$APP_BUNDLE/Contents/Resources/whisper/whisper-server" ]; then
    runtime_directory="$APP_BUNDLE/Contents/Resources/whisper"
    (cd "$runtime_directory" && shasum -a 256 whisper-server) > "$runtime_directory/SHA256SUMS.txt"
    if [ -f "$runtime_directory/whisper-cli" ]; then
        (cd "$runtime_directory" && shasum -a 256 whisper-cli) >> "$runtime_directory/SHA256SUMS.txt"
    fi
fi
codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none \
    --entitlements "$SCRIPT_DIR/../InputSa/Resources/InputSa.entitlements" "$APP_BUNDLE"
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo "Signature verified: $APP_BUNDLE"
