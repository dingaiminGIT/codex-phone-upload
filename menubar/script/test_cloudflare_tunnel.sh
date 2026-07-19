#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-phone-upload-tunnel-tests.XXXXXX")"
trap '/bin/rm -rf "$BUILD_DIR"' EXIT

/usr/bin/xcrun swiftc \
  "$ROOT_DIR/Sources/CodexPhoneUploadMenu/CloudflareTunnel.swift" \
  "$ROOT_DIR/Tests/CloudflareTunnelTests/CloudflareTunnelTests.swift" \
  -o "$BUILD_DIR/CloudflareTunnelSelfTests"

"$BUILD_DIR/CloudflareTunnelSelfTests"
