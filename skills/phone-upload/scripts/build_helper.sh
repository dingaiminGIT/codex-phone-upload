#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/paste_files.swift"
OUTPUT="$SCRIPT_DIR/paste_files"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-phone-upload-helper.XXXXXX")"
trap 'find "$BUILD_DIR" -depth -delete 2>/dev/null || true' EXIT

COMMON_ARGS=(
  -O
  -framework AppKit
  -framework ApplicationServices
  -framework CoreImage
  "$SOURCE"
)

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "The Codex paste helper can only be built on macOS." >&2
  exit 1
fi

/usr/bin/xcrun swiftc -target arm64-apple-macos14.0 "${COMMON_ARGS[@]}" -o "$BUILD_DIR/paste_files-arm64"
/usr/bin/xcrun swiftc -target x86_64-apple-macos14.0 "${COMMON_ARGS[@]}" -o "$BUILD_DIR/paste_files-x86_64"
/usr/bin/lipo -create "$BUILD_DIR/paste_files-arm64" "$BUILD_DIR/paste_files-x86_64" -output "$OUTPUT"
/bin/chmod +x "$OUTPUT"
/usr/bin/codesign --force --sign - "$OUTPUT" >/dev/null

/usr/bin/file "$OUTPUT"
