#!/usr/bin/env bash
set -euo pipefail

IDENTITY_NAME="Codex Phone Upload Local Signing"
LOGIN_KEYCHAIN="${CODEX_PHONE_UPLOAD_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
SIGNING_STAGING_DIR=""

cleanup() {
  if [[ -n "$SIGNING_STAGING_DIR" && -d "$SIGNING_STAGING_DIR" ]]; then
    /usr/bin/find "$SIGNING_STAGING_DIR" -depth -delete 2>/dev/null || true
  fi
}

trap cleanup EXIT

info() {
  printf '==> %s\n' "$1" >&2
}

fail() {
  printf 'Error: %s\n' "$1" >&2
  exit 1
}

identity_hash() {
  /usr/bin/security find-certificate -c "$IDENTITY_NAME" -Z "$LOGIN_KEYCHAIN" 2>/dev/null | \
    /usr/bin/awk '/SHA-1 hash:/ { print $3; exit }'
}

create_identity() {
  local staging_dir config_path key_path certificate_path archive_path archive_password
  staging_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/codex-phone-upload-signing.XXXXXX")"
  SIGNING_STAGING_DIR="$staging_dir"
  /bin/chmod 700 "$staging_dir"
  config_path="$staging_dir/openssl.cnf"
  key_path="$staging_dir/signing-key.pem"
  certificate_path="$staging_dir/signing-certificate.pem"
  archive_path="$staging_dir/signing-identity.p12"
  archive_password="$(/usr/bin/openssl rand -hex 24)"

  /bin/cat > "$config_path" <<EOF
[req]
prompt = no
distinguished_name = subject
x509_extensions = extensions

[subject]
CN = $IDENTITY_NAME
O = Codex Phone Upload

[extensions]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = codeSigning
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid
EOF

  /usr/bin/openssl req \
    -new -newkey rsa:2048 -nodes -x509 -sha256 -days 3650 \
    -config "$config_path" \
    -keyout "$key_path" \
    -out "$certificate_path" >/dev/null 2>&1
  /bin/chmod 600 "$key_path" "$certificate_path"

  /usr/bin/openssl pkcs12 -export \
    -inkey "$key_path" \
    -in "$certificate_path" \
    -name "$IDENTITY_NAME" \
    -passout "pass:$archive_password" \
    -out "$archive_path" >/dev/null 2>&1
  /bin/chmod 600 "$archive_path"

  /usr/bin/security import "$archive_path" \
    -k "$LOGIN_KEYCHAIN" \
    -f pkcs12 \
    -P "$archive_password" \
    -x \
    -T /usr/bin/codesign >/dev/null
  /usr/bin/find "$staging_dir" -depth -delete
  SIGNING_STAGING_DIR=""
}

ensure_identity() {
  local hash
  hash="$(identity_hash)"
  if [[ -n "$hash" ]]; then
    printf '%s\n' "$hash"
    return
  fi

  info "Creating a free, per-Mac signing identity in your login keychain"
  create_identity
  hash="$(identity_hash)"
  [[ -n "$hash" ]] || fail "The local signing identity was created but macOS does not consider it valid for code signing."
  printf '%s\n' "$hash"
}

case "${1:-status}" in
  ensure)
    ensure_identity
    ;;
  identity)
    identity_hash
    ;;
  status)
    if hash="$(identity_hash)" && [[ -n "$hash" ]]; then
      printf 'ready\t%s\t%s\n' "$hash" "$IDENTITY_NAME"
    else
      printf 'missing\t%s\n' "$IDENTITY_NAME"
      exit 1
    fi
    ;;
  *)
    fail "Usage: $0 [status|identity|ensure]"
    ;;
esac
