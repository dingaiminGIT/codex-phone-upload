#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_URL="https://github.com/dingaiminGIT/codex-phone-upload.git"
SOURCE_DIR="${CODEX_PHONE_UPLOAD_SOURCE:-$HOME/.local/share/codex-phone-upload}"
APP_DIR="${CODEX_PHONE_UPLOAD_APP_DIR:-$HOME/Applications}"
SKILLS_DIR="${CODEX_PHONE_UPLOAD_SKILLS_DIR:-$HOME/.codex/skills}"
SKILL_LINK="$SKILLS_DIR/phone-upload"
LOCAL_SIGNING_NAME="Codex Phone Upload Local Signing"

info() {
  printf '\n==> %s\n' "$1"
}

fail() {
  printf '\nError: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf '\nWarning: %s\n' "$1" >&2
}

cloudflared_installed() {
  command -v cloudflared >/dev/null 2>&1 || \
    [[ -x /opt/homebrew/bin/cloudflared ]] || \
    [[ -x /usr/local/bin/cloudflared ]]
}

install_cloudflared_if_possible() {
  if cloudflared_installed; then
    info "Cloudflare public mode is ready"
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    info "Installing cloudflared for optional public HTTPS mode"
    if ! brew install cloudflared; then
      warn "cloudflared could not be installed. Same-Wi-Fi mode will still work; run 'brew install cloudflared' later to enable public mode."
    fi
  else
    warn "Homebrew is not installed, so cloudflared was skipped. Same-Wi-Fi mode will work; public HTTPS mode needs cloudflared."
  fi
}

configure_local_signing() {
  local setting answer identity
  setting="${CODEX_PHONE_UPLOAD_LOCAL_SIGNING:-ask}"

  case "$setting" in
    0|no|false)
      warn "Stable local signing was skipped. A future rebuild may require Accessibility permission again."
      export CODEX_PHONE_UPLOAD_SIGNING_IDENTITY="-"
      return
      ;;
    1|yes|true|ask)
      ;;
    *)
      fail "CODEX_PHONE_UPLOAD_LOCAL_SIGNING must be 1, 0, or ask."
      ;;
  esac

  if identity="$($SOURCE_DIR/menubar/script/local_signing.sh identity 2>/dev/null)" && [[ -n "$identity" ]]; then
    info "Reusing the stable local signing identity"
    export CODEX_PHONE_UPLOAD_SIGNING_IDENTITY="$identity"
    return
  fi

  case "$setting" in
    1|yes|true)
      ;;
    ask)
      if [[ ! -t 0 ]]; then
        warn "Stable local signing was skipped in a non-interactive install. Set CODEX_PHONE_UPLOAD_LOCAL_SIGNING=1 to enable it."
        return
      fi
      printf '\nCodex Phone Upload can create a free signing identity named:\n  %s\n\n' "$LOCAL_SIGNING_NAME"
      printf 'It stays in this Mac login keychain, is not added to system trust, and helps Accessibility permission survive app updates.\n'
      printf 'This is not Apple notarization and does not make downloads trusted on other Macs.\n\n'
      read -r -p 'Create and use this local signing identity? [Y/n] ' answer
      case "$answer" in
        ''|y|Y|yes|YES|Yes)
          ;;
        *)
          warn "Stable local signing was skipped. A future rebuild may require Accessibility permission again."
          return
          ;;
      esac
      ;;
  esac

  info "Configuring the stable local signing identity"
  identity="$($SOURCE_DIR/menubar/script/local_signing.sh ensure)"
  export CODEX_PHONE_UPLOAD_SIGNING_IDENTITY="$identity"
  printf 'The first build may show a Keychain dialog for “%s”.\n' "$LOCAL_SIGNING_NAME"
  printf 'Enter your Mac login password and choose “Always Allow” once. Do not approve prompts for unrelated items.\n'
}

[[ "$(uname -s)" == "Darwin" ]] || fail "Codex Phone Upload currently supports macOS only."
command -v git >/dev/null 2>&1 || fail "Git is required. Install Xcode Command Line Tools, then run this command again."

if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  /usr/bin/xcode-select --install >/dev/null 2>&1 || true
  fail "Finish installing Xcode Command Line Tools in the macOS dialog, then run this same command again."
fi

if [[ -z "${CODEX_PHONE_UPLOAD_SOURCE:-}" ]]; then
  if [[ -d "$SOURCE_DIR/.git" ]]; then
    info "Updating Codex Phone Upload"
    /usr/bin/git -C "$SOURCE_DIR" pull --ff-only
  elif [[ -e "$SOURCE_DIR" ]]; then
    fail "$SOURCE_DIR already exists but is not a Git checkout. Move it aside and retry."
  else
    info "Downloading Codex Phone Upload"
    /bin/mkdir -p "$(dirname "$SOURCE_DIR")"
    /usr/bin/git clone --depth 1 "$REPOSITORY_URL" "$SOURCE_DIR"
  fi
else
  [[ -d "$SOURCE_DIR/menubar" && -d "$SOURCE_DIR/skills/phone-upload" ]] || \
    fail "CODEX_PHONE_UPLOAD_SOURCE does not point to a valid checkout."
fi

install_cloudflared_if_possible
configure_local_signing

if [[ -e "$SKILL_LINK" && ! -L "$SKILL_LINK" ]]; then
  fail "$SKILL_LINK already exists and is not a symbolic link. Move it aside and retry."
fi

info "Installing the macOS app"
CODEX_PHONE_UPLOAD_INSTALL_DIR="$APP_DIR" \
  "$SOURCE_DIR/menubar/script/build_and_run.sh" --install

info "Installing the Codex Skill"
/bin/mkdir -p "$SKILLS_DIR"
/bin/ln -sfn "$SOURCE_DIR/skills/phone-upload" "$SKILL_LINK"

printf '\nInstallation complete.\n\n'
printf 'App:   %s/CodexPhoneUpload.app\n' "$APP_DIR"
printf 'Skill: %s\n\n' "$SKILL_LINK"
printf 'Next steps:\n'
printf '1. In System Settings > Privacy & Security > Accessibility, enable CodexPhoneUpload.\n'
printf '2. Restart Codex once so it discovers the Skill.\n'
printf '3. Open CodexPhoneUpload from Spotlight, scan the QR code, and upload your images.\n\n'
