#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Live Wallpapers for Mac"
PACKAGE_PRODUCT="Live Wallpapers for Mac"
BUNDLE_ID="com.medusa411.LiveWallpapersForMac"
EXECUTABLE_NAME="Live Wallpapers for Mac"
MIN_SYSTEM_VERSION="13.0"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-Live Wallpapers for Mac Release Signing}"

VERSION="${1:-${APP_VERSION:-0.1.0}}"
BUILD_NUMBER="${2:-${APP_BUILD:-$(date +%Y%m%d%H%M)}}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/dist/release"
APP_BUNDLE="$RELEASE_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$EXECUTABLE_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
BASELINE_DIR="$ROOT_DIR/release"
EXPECTED_REQUIREMENT="$BASELINE_DIR/designated-requirement.txt"
EXPECTED_CERT_SHA1="$BASELINE_DIR/certificate-sha1.txt"
CURRENT_REQUIREMENT="$RELEASE_DIR/designated-requirement.txt"
CURRENT_CERT_SHA1="$RELEASE_DIR/certificate-sha1.txt"
ZIP_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.zip"
DMG_PATH="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
DMG_STAGING_DIR="$RELEASE_DIR/dmg-staging"
DMG_VOLUME_NAME="Live Wallpapers $VERSION"

fail() {
  echo "error: $*" >&2
  exit 1
}

plist_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$INFO_PLIST"
}

require_signing_identity() {
  if ! /usr/bin/security find-identity -v -p codesigning -s "$SIGNING_IDENTITY" | grep -F "\"$SIGNING_IDENTITY\"" >/dev/null; then
    fail "required signing identity not found: $SIGNING_IDENTITY"
  fi
}

write_info_plist() {
  cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$EXECUTABLE_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST
}

verify_bundle_invariants() {
  /usr/bin/plutil -lint "$INFO_PLIST" >/dev/null
  [[ "$(plist_value CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "CFBundleIdentifier changed"
  [[ "$(plist_value CFBundleExecutable)" == "$EXECUTABLE_NAME" ]] || fail "CFBundleExecutable changed"
  [[ "$(basename "$APP_BUNDLE")" == "$APP_NAME.app" ]] || fail "app bundle name changed"
  [[ "$(basename "$APP_BINARY")" == "$EXECUTABLE_NAME" ]] || fail "executable name changed"
}

extract_signature_facts() {
  /usr/bin/codesign -d -r- "$APP_BUNDLE" 2>&1 | sed -n '/^designated =>/,$p' >"$CURRENT_REQUIREMENT"
  grep -F "identifier \"$BUNDLE_ID\"" "$CURRENT_REQUIREMENT" >/dev/null || fail "designated requirement does not contain $BUNDLE_ID"
  if grep -q "cdhash" "$CURRENT_REQUIREMENT"; then
    fail "designated requirement contains cdhash; release signature is not stable enough for TCC"
  fi

  local leaf_sha1
  leaf_sha1="$(sed -n 's/.*certificate leaf = H"\([0-9A-Fa-f]*\)".*/\1/p' "$CURRENT_REQUIREMENT" | head -1)"
  [[ -n "$leaf_sha1" ]] || fail "designated requirement does not contain a leaf certificate fingerprint"
  printf '%s\n' "$leaf_sha1" | tr '[:lower:]' '[:upper:]' >"$CURRENT_CERT_SHA1"
}

compare_or_initialize_baseline() {
  mkdir -p "$BASELINE_DIR"

  if [[ -f "$EXPECTED_REQUIREMENT" ]]; then
    diff -u "$EXPECTED_REQUIREMENT" "$CURRENT_REQUIREMENT" >/dev/null \
      || fail "designated requirement changed; TCC permissions may be lost"
  else
    cp "$CURRENT_REQUIREMENT" "$EXPECTED_REQUIREMENT"
    echo "initialized release/designated-requirement.txt"
  fi

  if [[ -f "$EXPECTED_CERT_SHA1" ]]; then
    diff -u "$EXPECTED_CERT_SHA1" "$CURRENT_CERT_SHA1" >/dev/null \
      || fail "signing certificate fingerprint changed; TCC permissions may be lost"
  else
    cp "$CURRENT_CERT_SHA1" "$EXPECTED_CERT_SHA1"
    echo "initialized release/certificate-sha1.txt"
  fi
}

require_signing_identity

cd "$ROOT_DIR"
swift build -c release --product "$PACKAGE_PRODUCT"
BUILD_BINARY="$(swift build -c release --show-bin-path)/$PACKAGE_PRODUCT"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ -d "$ROOT_DIR/Resources" ]]; then
  cp -R "$ROOT_DIR/Resources/." "$APP_RESOURCES/"
fi

write_info_plist
verify_bundle_invariants

/usr/bin/codesign --force --deep --strict --options runtime --timestamp=none \
  --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
/usr/bin/codesign -d -r- "$APP_BUNDLE"

extract_signature_facts
compare_or_initialize_baseline

rm -f "$ZIP_PATH" "$ZIP_PATH.sha256" "$DMG_PATH" "$DMG_PATH.sha256"
(
  cd "$RELEASE_DIR"
  /usr/bin/ditto -c -k --keepParent "$APP_NAME.app" "$ZIP_PATH"
  /usr/bin/shasum -a 256 "$(basename "$ZIP_PATH")" >"$ZIP_PATH.sha256"
)

rm -rf "$DMG_STAGING_DIR"
mkdir -p "$DMG_STAGING_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$DMG_STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
cp "$ROOT_DIR/INSTALL_RU.txt" "$DMG_STAGING_DIR/Установка — прочитайте.txt"
cp "$ROOT_DIR/INSTALL_EN.txt" "$DMG_STAGING_DIR/Installation — read me.txt"

/usr/bin/hdiutil create \
  -volname "$DMG_VOLUME_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"
rm -rf "$DMG_STAGING_DIR"

(
  cd "$RELEASE_DIR"
  /usr/bin/shasum -a 256 "$(basename "$DMG_PATH")" >"$DMG_PATH.sha256"
)

DMG_MOUNT_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/live-wallpapers-dmg.XXXXXX")"
cleanup_dmg_mount() {
  /usr/bin/hdiutil detach "$DMG_MOUNT_DIR" -quiet >/dev/null 2>&1 || true
  rmdir "$DMG_MOUNT_DIR" >/dev/null 2>&1 || true
}
trap cleanup_dmg_mount EXIT

/usr/bin/hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$DMG_MOUNT_DIR" -quiet
DMG_APP="$DMG_MOUNT_DIR/$APP_NAME.app"
[[ -d "$DMG_APP" ]] || fail "DMG does not contain $APP_NAME.app"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$DMG_APP"
/usr/bin/codesign -d -r- "$DMG_APP" 2>&1 | sed -n '/^designated =>/,$p' \
  | diff -u "$EXPECTED_REQUIREMENT" - >/dev/null \
  || fail "application signature changed inside DMG"
cleanup_dmg_mount
trap - EXIT

echo "release app: $APP_BUNDLE"
echo "release zip: $ZIP_PATH"
echo "release dmg: $DMG_PATH"
echo "install path must stay: /Applications/$APP_NAME.app"
