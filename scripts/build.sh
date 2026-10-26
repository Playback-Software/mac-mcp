#!/bin/zsh
# Build, bundle, sign and install MacMCP.app + the mac-mcp CLI, then (re)start the LaunchAgent.
# Signing identity, in order: MAC_MCP_SIGNING_IDENTITY; else the one identity in the dedicated signing keychain
# (scripts/setup-signing.sh creates it, and it lets builds run unattended over SSH); else the one valid code-signing
# identity in your login keychain (e.g. a free Apple Development certificate from Xcode).
#
#   scripts/build.sh            build + install + restart agent
#   scripts/build.sh --no-start build + install files only
# Refuses while another client holds the GUI lease (an eval or GUI test run); MAC_MCP_FORCE=1 overrides.
set -euo pipefail
cd "${0:A:h}/.."
source "${0:A:h}/toolchain.sh"

if [[ -x "$HOME/.local/bin/mac-mcp" && "${MAC_MCP_FORCE:-}" != 1 ]]; then
  lease=$("$HOME/.local/bin/mac-mcp" lease status 2>/dev/null) && rc=0 || rc=$?
  if (( rc == 3 )); then   # 3: someone else holds it (older CLIs without `lease` fail differently)
    print -u2 "build.sh: not replacing the agent: the GUI is ${lease#leased: }"
    print -u2 "          Wait for it to finish, or set MAC_MCP_FORCE=1."
    exit 1
  fi
fi
scripts/lint-blocking.sh

APP="$HOME/Applications/MacMCP.app"
CLI="$HOME/.local/bin/mac-mcp"
KC="${MAC_MCP_SIGNING_KEYCHAIN:-$HOME/Library/Keychains/mac-mcp-signing.keychain-db}"
KC_PASS="${MAC_MCP_SIGNING_KEYCHAIN_PASS:-$HOME/.config/mac-mcp/signing-keychain.pass}"
# The designated requirement pins the signing certificate, so permission grants survive rebuilds as long as the
# identity stays the same. Changing it means granting Accessibility and Screen Recording once more.
IDENTITY="${MAC_MCP_SIGNING_IDENTITY:-}"
KC_ARGS=()
# `SHA-1 "name"` lines for the code-signing identities `security find-identity` lists (args: -v, a keychain path).
listing() { security find-identity -p codesigning "$@" 2>/dev/null | sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) \(".*"\).*/\1 \2/p' | sort -u }
if [[ -f "$KC" && -f "$KC_PASS" ]]; then
  security unlock-keychain -p "$(<"$KC_PASS")" "$KC"   # no prompts; works without a GUI session
  KC_ARGS=(--keychain "$KC")
  found=$(listing "$KC")   # self-signed certificates count here, so not -v
  where="the signing keychain $KC"
else
  found=$(listing -v)
  where="your keychains"
fi
if [[ -z "$IDENTITY" ]]; then
  if [[ -z "$found" ]]; then
    print -u2 "build.sh: no code-signing identity in $where."
    print -u2 "  Run scripts/setup-signing.sh once to create a local signing certificate (or --import yours),"
    print -u2 "  or set MAC_MCP_SIGNING_IDENTITY to a certificate's SHA-1. See docs/architecture.md#signing."
    exit 1
  elif [[ "$found" == *$'\n'* ]]; then
    print -u2 "build.sh: several code-signing identities in $where; set MAC_MCP_SIGNING_IDENTITY to one SHA-1:"
    print -u2 -- "$found"
    exit 1
  fi
  IDENTITY=${found%% *}
fi
VERSION=0.1.0
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo dev)$(git diff --quiet HEAD 2>/dev/null || echo +dirty)-$(date +%Y%m%d%H%M%S)"

swift build -c release --product MacMCPAgent
swift build -c release --product mac-mcp
BIN=.build/release

# Bundle. The path and bundle ID must stay fixed: permission grants follow them plus the signing identity.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MacMCPAgent" "$APP/Contents/MacOS/"
cp assets/branding/MacMCP.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.playbacksoftware.macmcp</string>
  <key>CFBundleName</key><string>MacMCP</string>
  <key>CFBundleDisplayName</key><string>MacMCP</string>
  <key>CFBundleExecutable</key><string>MacMCPAgent</string>
  <key>CFBundleIconFile</key><string>MacMCP.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Playback Software, LLC</string>
  <key>NSAppleEventsUsageDescription</key><string>MacMCP runs AppleScript in apps you allow in its policy, on behalf of automation agents.</string>
</dict></plist>
EOF

sign_failed() {
  print -u2 "build.sh: codesign failed. Over SSH the login keychain is locked; scripts/setup-signing.sh sets up a"
  print -u2 "  dedicated keychain that works unattended."
  exit 1
}
codesign --force "${KC_ARGS[@]}" -s "$IDENTITY" -o runtime --timestamp=none --entitlements scripts/MacMCP.entitlements "$APP" || sign_failed
mkdir -p "${CLI:h}"
cp "$BIN/mac-mcp" "$CLI"
codesign --force "${KC_ARGS[@]}" -s "$IDENTITY" -o runtime --timestamp=none -i com.playbacksoftware.macmcp.cli "$CLI" || sign_failed
codesign --verify --strict "$APP"
echo "built MacMCP $VERSION ($BUILD), signed by ${IDENTITY[1,8]}…, team $(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"

[[ "${1:-}" == "--no-start" ]] && exit 0
"$CLI" install
