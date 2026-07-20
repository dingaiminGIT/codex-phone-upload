#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexPhoneUpload"
BUNDLE_ID="local.dingaimin.CodexPhoneUpload"
INSTALL_DIR="${CODEX_PHONE_UPLOAD_INSTALL_DIR:-$HOME/Applications}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
LOCAL_SIGNING_SCRIPT="$ROOT_DIR/script/local_signing.sh"

resolve_signing_identity() {
  if [[ -n "${CODEX_PHONE_UPLOAD_SIGNING_IDENTITY:-}" ]]; then
    printf '%s\n' "$CODEX_PHONE_UPLOAD_SIGNING_IDENTITY"
    return
  fi

  local local_identity
  local_identity="$($LOCAL_SIGNING_SCRIPT identity 2>/dev/null || true)"
  if [[ -n "$local_identity" ]]; then
    printf '%s\n' "$local_identity"
  else
    printf '%s\n' '-'
  fi
}

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift build --package-path "$ROOT_DIR"
BUILD_BINARY="$(swift build --package-path "$ROOT_DIR" --show-bin-path)/$APP_NAME"

if [[ -d "$APP_BUNDLE" ]]; then
  find "$APP_BUNDLE" -depth -delete
fi
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
cp "$ROOT_DIR/Resources/Info.plist" "$APP_CONTENTS/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
find "$ROOT_DIR/Resources" -mindepth 1 -maxdepth 1 -type d -name '*.lproj' -exec cp -R {} "$APP_RESOURCES/" \;
chmod +x "$APP_BINARY"
SIGNING_IDENTITY="$(resolve_signing_identity)"
/usr/bin/codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_BUNDLE" >/dev/null
if [[ "$SIGNING_IDENTITY" == "-" ]]; then
  echo "Signed with an ad-hoc identity (local stable signing is not configured)." >&2
else
  echo "Signed with the stable local identity: $SIGNING_IDENTITY" >&2
fi

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --build|build)
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
    for _ in 1 2 3 4 5; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 1
    done
    echo "$APP_NAME did not stay running" >&2
    exit 1
    ;;
  --install|install)
    INSTALLED_APP="$INSTALL_DIR/$APP_NAME.app"
    mkdir -p "$INSTALL_DIR"
    if [[ -d "$INSTALLED_APP" ]]; then
      find "$INSTALLED_APP" -depth -delete
    fi
    cp -R "$APP_BUNDLE" "$INSTALLED_APP"
    LEGACY_APP="$INSTALL_DIR/CodexPhoneUploadMenu.app"
    if [[ -d "$LEGACY_APP" ]]; then
      find "$LEGACY_APP" -depth -delete
    fi
    if [[ "${CODEX_PHONE_UPLOAD_SKIP_OPEN:-0}" != "1" ]]; then
      /usr/bin/open -n "$INSTALLED_APP"
    fi
    echo "$INSTALLED_APP"
    ;;
  *)
    echo "usage: $0 [run|--build|--debug|--logs|--telemetry|--verify|--install]" >&2
    exit 2
    ;;
esac
