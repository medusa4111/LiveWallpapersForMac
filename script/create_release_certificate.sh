#!/usr/bin/env bash
set -euo pipefail

IDENTITY="${SIGNING_IDENTITY:-Live Wallpapers for Mac Release Signing}"
KEYCHAIN="${KEYCHAIN:-$(/usr/bin/security login-keychain | tr -d '\" ')}"
DAYS="${CERT_DAYS:-3650}"

if /usr/bin/security find-identity -v -p codesigning -s "$IDENTITY" | grep -F "\"$IDENTITY\"" >/dev/null; then
  echo "signing identity already exists: $IDENTITY"
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
P12_PASSWORD="$(/usr/bin/uuidgen)"

cat >"$TMP_DIR/openssl.cnf" <<CONF
[ req ]
distinguished_name = req_distinguished_name
x509_extensions = codesign
prompt = no

[ req_distinguished_name ]
CN = $IDENTITY

[ codesign ]
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature,keyCertSign,cRLSign
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
CONF

/usr/bin/openssl req -new -newkey rsa:4096 -nodes -x509 -sha256 -days "$DAYS" \
  -config "$TMP_DIR/openssl.cnf" \
  -keyout "$TMP_DIR/signing.key" \
  -out "$TMP_DIR/signing.crt"

/usr/bin/openssl pkcs12 -export \
  -inkey "$TMP_DIR/signing.key" \
  -in "$TMP_DIR/signing.crt" \
  -name "$IDENTITY" \
  -out "$TMP_DIR/signing.p12" \
  -passout "pass:$P12_PASSWORD"

/usr/bin/security import "$TMP_DIR/signing.p12" \
  -k "$KEYCHAIN" \
  -P "$P12_PASSWORD" \
  -A

/usr/bin/security find-identity -v -p codesigning -s "$IDENTITY" | grep -F "\"$IDENTITY\"" >/dev/null \
  || {
    echo "error: identity was imported but is not available for codesigning: $IDENTITY" >&2
    exit 1
  }

echo "created signing identity: $IDENTITY"
echo "do not delete or recreate this certificate after the first public release."
