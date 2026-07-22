#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Live Wallpapers for Mac"
BUNDLE_ID="com.medusa411.LiveWallpapersForMac"
EXECUTABLE_NAME="Live Wallpapers for Mac"
INSTALL_PATH="/Applications/$APP_NAME.app"
VERIFY_ONLY=false

if [[ "${1:-}" == "--verify-only" ]]; then
  VERIFY_ONLY=true
  shift
fi

ARCHIVE_PATH="${1:-}"
[[ -n "$ARCHIVE_PATH" ]] || {
  echo "usage: $0 [--verify-only] /path/to/Live Wallpapers for Mac-version.zip" >&2
  exit 2
}

fail() {
  echo "error: $*" >&2
  exit 1
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

/usr/bin/ditto -x -k "$ARCHIVE_PATH" "$TMP_DIR"
CANDIDATE="$TMP_DIR/$APP_NAME.app"
[[ -d "$CANDIDATE" ]] || fail "archive does not contain $APP_NAME.app"

INFO_PLIST="$CANDIDATE/Contents/Info.plist"
APP_BINARY="$CANDIDATE/Contents/MacOS/$EXECUTABLE_NAME"
[[ -x "$APP_BINARY" ]] || fail "candidate executable is missing: $EXECUTABLE_NAME"

plist_value() {
  /usr/bin/plutil -extract "$1" raw -o - "$INFO_PLIST"
}

[[ "$(plist_value CFBundleIdentifier)" == "$BUNDLE_ID" ]] || fail "candidate Bundle ID mismatch"
[[ "$(plist_value CFBundleExecutable)" == "$EXECUTABLE_NAME" ]] || fail "candidate executable name mismatch"
[[ "$(basename "$CANDIDATE")" == "$APP_NAME.app" ]] || fail "candidate app name mismatch"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$CANDIDATE"

CANDIDATE_REQUIREMENT="$TMP_DIR/candidate.requirement.txt"
/usr/bin/codesign -d -r- "$CANDIDATE" 2>&1 | sed -n '/^designated =>/,$p' >"$CANDIDATE_REQUIREMENT"
grep -F "identifier \"$BUNDLE_ID\"" "$CANDIDATE_REQUIREMENT" >/dev/null \
  || fail "candidate designated requirement does not contain $BUNDLE_ID"
if grep -q "cdhash" "$CANDIDATE_REQUIREMENT"; then
  fail "candidate designated requirement contains cdhash"
fi

if [[ -d "$INSTALL_PATH" ]]; then
  INSTALLED_REQUIREMENT="$TMP_DIR/installed.requirement.txt"
  /usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"
  /usr/bin/codesign -d -r- "$INSTALL_PATH" 2>&1 | sed -n '/^designated =>/,$p' >"$INSTALLED_REQUIREMENT"
  diff -u "$INSTALLED_REQUIREMENT" "$CANDIDATE_REQUIREMENT" >/dev/null \
    || fail "candidate is not the same designated application as the installed app"
fi

if [[ "$VERIFY_ONLY" == true ]]; then
  /usr/bin/codesign -d -r- "$CANDIDATE"
  echo "verified update archive: $ARCHIVE_PATH"
  exit 0
fi

if [[ ! -w "/Applications" ]]; then
  fail "/Applications is not writable. Run this installer from an administrator account."
fi

/usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
for _ in {1..40}; do
  if ! pgrep -f "$INSTALL_PATH/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

BACKUP_PATH="$TMP_DIR/$APP_NAME.previous.app"
if [[ -d "$INSTALL_PATH" ]]; then
  mv "$INSTALL_PATH" "$BACKUP_PATH"
fi

if ! /usr/bin/ditto "$CANDIDATE" "$INSTALL_PATH"; then
  rm -rf "$INSTALL_PATH"
  if [[ -d "$BACKUP_PATH" ]]; then
    mv "$BACKUP_PATH" "$INSTALL_PATH"
  fi
  fail "failed to install update; previous app restored"
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$INSTALL_PATH"
/usr/bin/codesign -d -r- "$INSTALL_PATH"
/usr/bin/open "$INSTALL_PATH"

echo "updated: $INSTALL_PATH"
