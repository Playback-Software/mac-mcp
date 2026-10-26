#!/bin/zsh
# One-time signing setup for scripts/build.sh: a dedicated keychain holding the identity MacMCP is signed with.
# macOS ties the Accessibility and Screen Recording grants to that identity, so keep it: re-creating it means granting
# both permissions again. A dedicated keychain (not the login keychain) lets builds run unattended over SSH.
#
#   scripts/setup-signing.sh                   create a self-signed "MacMCP Local Development" certificate
#   scripts/setup-signing.sh --import ID.p12   import an identity you exported (Apple Development or Developer ID)
#
# Uses MAC_MCP_SIGNING_KEYCHAIN and MAC_MCP_SIGNING_KEYCHAIN_PASS when set, like build.sh.
set -euo pipefail
KC="${MAC_MCP_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/mac-mcp-signing.keychain-db}"
KC_PASS="${MAC_MCP_SIGNING_KEYCHAIN_PASS:-$HOME/.config/mac-mcp/signing-keychain.pass}"
NAME="MacMCP Local Development"

mode=self-signed p12=
case "${1:-}" in
  "") ;;
  --import) [[ -f "${2:-}" ]] || { print -u2 "usage: $0 --import IDENTITY.p12"; exit 2 }; mode=import p12=$2 ;;
  *) print -u2 "usage: $0 [--import IDENTITY.p12]"; exit 2 ;;
esac

if [[ -e "$KC" ]]; then
  print -u2 "setup-signing.sh: $KC already exists; nothing changed."
  print -u2 "  Its identities: security find-identity -p codesigning \"$KC\""
  print -u2 "  To start over (MacMCP's permission grants will need approving again): security delete-keychain \"$KC\""
  exit 1
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/mac-mcp-signing.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
mkdir -p "${KC_PASS:h}" "${KC:h}"
( umask 077; /usr/bin/openssl rand -hex 16 > "$KC_PASS" )
security create-keychain -p "$(<"$KC_PASS")" "$KC"
security set-keychain-settings "$KC"   # no auto-lock timeout; build.sh unlocks it anyway

if [[ $mode == self-signed ]]; then
  # The system LibreSSL writes a PKCS#12 that `security import` reads (OpenSSL 3's defaults may not be).
  cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
  P12_PASS=$(/usr/bin/openssl rand -hex 16)
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/id.p12" -passout "pass:$P12_PASS"
  p12=$WORK/id.p12
else
  read -s "P12_PASS?Password for $p12: "; echo
fi
security import "$p12" -k "$KC" -f pkcs12 -P "$P12_PASS" -T /usr/bin/codesign >/dev/null
unset P12_PASS
# Lets codesign use the key without a GUI prompt.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$(<"$KC_PASS")" "$KC" >/dev/null

security find-identity -p codesigning "$KC" | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(.*\)".*/\1 \2/p' | while read -r sha label; do
  print "Signing identity ready: $label ($sha)"
done
print "Keychain: $KC (password in $KC_PASS, mode 0600)"
print "Next: scripts/build.sh"
