#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Live Wallpapers for Mac"
PACKAGE_PRODUCT="Live Wallpapers for Mac"
BUNDLE_ID="com.medusa411.LiveWallpapersForMac"
MIN_SYSTEM_VERSION="13.0"
APP_VERSION="${APP_VERSION:-0.1.0}"
APP_BUILD="${APP_BUILD:-1}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"

if pgrep -f "$APP_BINARY" >/dev/null 2>&1; then
  pkill -TERM -f "$APP_BINARY" >/dev/null 2>&1 || true

  for _ in {1..30}; do
    if ! pgrep -f "$APP_BINARY" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done

  pkill -KILL -f "$APP_BINARY" >/dev/null 2>&1 || true
fi

swift build --product "$PACKAGE_PRODUCT"
BUILD_BINARY="$(swift build --show-bin-path)/$PACKAGE_PRODUCT"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
if [[ -d "$ROOT_DIR/Resources" ]]; then
  cp -R "$ROOT_DIR/Resources/." "$APP_RESOURCES/"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
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
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
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

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

open_app_with_video() {
  if [[ $# -lt 1 || -z "$1" ]]; then
    echo "usage: $0 --video /path/to/video [--trim-start seconds] [--trim-end seconds]" >&2
    exit 2
  fi

  local video_path="$1"
  shift
  /usr/bin/open -n "$APP_BUNDLE" --args --video "$video_path" "$@"
}

open_app_with_image() {
  if [[ $# -lt 1 || -z "$1" ]]; then
    echo "usage: $0 --image /path/to/image-or-gif" >&2
    exit 2
  fi

  /usr/bin/open -n "$APP_BUNDLE" --args --image "$1"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -f "$APP_BINARY" >/dev/null
    ;;
  --settings|settings)
    /usr/bin/open -n "$APP_BUNDLE" --args --settings
    ;;
  --video|video)
    shift
    open_app_with_video "$@"
    ;;
  --image|image)
    shift
    open_app_with_image "$@"
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--settings|--video /path/to/video [--trim-start seconds] [--trim-end seconds]|--image /path/to/image-or-gif]" >&2
    exit 2
    ;;
esac
