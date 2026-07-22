#!/bin/bash
# create-signing-cert.sh — One-time setup of a PERSISTENT self-signed code-signing
# certificate for Input-sa. Signing every build/release with this ONE fixed cert
# keeps the app's "designated requirement" constant across versions, so macOS
# microphone / accessibility grants SURVIVE every future update (they key on the
# certificate, not on the per-build code hash the way ad-hoc signing does).
#
# Idempotent: safe to re-run; it skips creation if the identity already exists.
# Free, no Apple Developer account. Distributed apps are still un-notarized, so
# each person still right-click → Opens once on first install (a one-time thing,
# not per-version) — removing THAT requires Apple's paid notarization.
set -e

CERT_NAME="Input-sa Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
DAYS=3650   # ~10 years, so the cert itself never becomes the thing that expires

# Already installed? Then we're done.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ 簽章憑證「$CERT_NAME」已存在，不需重建。"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    exit 0
fi

echo "🔏 建立永久自簽的程式簽章憑證「$CERT_NAME」（約 10 年效期）..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# macOS ships LibreSSL, which lacks `-addext`; drive the codeSigning extensions
# through a config file instead (portable across LibreSSL/OpenSSL).
cat > "$TMP/cfg" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Input-sa Code Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days "$DAYS" -nodes \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null

# Bundle cert+key into a PKCS#12, then import into the login keychain, granting
# codesign (and security) access to the private key.
openssl pkcs12 -export -out "$TMP/id.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$CERT_NAME" -passout pass:inputsa 2>/dev/null

security import "$TMP/id.p12" -k "$KEYCHAIN" -P inputsa \
    -T /usr/bin/codesign -T /usr/bin/security 2>&1 || {
        echo "❌ 匯入 keychain 失敗。若出現密碼視窗請輸入你的 Mac 開機密碼後重跑本腳本。"
        exit 1
    }

# Trust the self-signed cert for code signing so `find-identity` lists it and
# codesign accepts it. User-domain trust (no sudo); may pop a one-time password
# dialog — that's expected and safe.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null \
    || echo "⚠️  自動信任設定未完成（不一定是問題）。若稍後簽章失敗，請到「鑰匙圈存取」把「$CERT_NAME」的『信任 → 程式碼簽署』設為『永遠信任』。"

echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "✅ 完成！以後 ./install.sh 與 ./package-release.sh 會自動用這張固定憑證簽章。"
    security find-identity -v -p codesigning | grep "$CERT_NAME"
    echo ""
    echo "   第一次用它簽章時，系統可能跳「codesign 想使用鑰匙圈裡的金鑰」，請按【總是允許】一次即可。"
else
    echo "⚠️  憑證已匯入但尚未被列為可用簽章身分。"
    echo "   請開啟「鑰匙圈存取」→ 找到「$CERT_NAME」→ 按兩下 → 展開『信任』→"
    echo "   把『程式碼簽署』設成『永遠信任』，關閉時輸入開機密碼，再重跑一次本腳本。"
    exit 1
fi
