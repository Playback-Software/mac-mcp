#!/bin/zsh
# Build, bundle, sign and install MacMCP.app + the mac-mcp CLI, then (re)start the LaunchAgent.
# Signing identity, in order: MAC_MCP_SIGNING_IDENTITY; else the one identity in the dedicated signing keychain
# (scripts/setup-signing.sh creates it, and it lets builds run unattended over SSH); else the one valid code-signing
# identity in your login keychain (e.g. a free Apple Development certificate from Xcode).
#
#   scripts/build.sh            build + install + restart agent
#   scripts/build.sh --no-start build + install files only
# Refuses while another client holds the GUI lease (an eval or GUI test run); MAC_MCP_FORCE=1 overrides. The lease is
# checked at the start and again right before the install, since a build can take minutes.
#
# The working install is never touched until its replacement is built, signed and verified in a staging directory.
# Then each is swapped in by rename; the old app stays as MacMCP.app.previous (and the old CLI as mac-mcp.previous)
# until the new agent answers a call, and is put back and restarted if it doesn't. One install runs at a time (a lock
# directory), and one that was cut short (Ctrl-C, a crash, power loss) is finished or undone before the next starts;
# scripts/install-swap.zsh has the details.
set -euo pipefail
cd "${0:A:h}/.."
source "${0:A:h}/toolchain.sh"
source "${0:A:h}/install-swap.zsh"

APP="$HOME/Applications/MacMCP.app"
CLI="$HOME/.local/bin/mac-mcp"
install_init
STAGE=""
STAGED_CLI=""
# An interrupt during the swap or the health check puts the previous install back (install_cleanup).
trap install_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
install_lock || exit 1
recover_install || exit 1

# Exits when someone else holds the GUI lease. Uses the installed CLI, the one that knows about the lease.
check_lease() {
  [[ -x "$CLI" && "${MAC_MCP_FORCE:-}" != 1 ]] || return 0
  local lease rc
  lease=$("$CLI" lease status 2>/dev/null) && rc=0 || rc=$?
  if (( rc == 3 )); then   # 3: someone else holds it (older CLIs without `lease` fail differently)
    print -u2 "build.sh: not replacing the agent: the GUI is ${lease#leased: }"
    print -u2 "          Wait for it to finish, or set MAC_MCP_FORCE=1."
    exit 1
  fi
}
check_lease
if (( NEEDS_RESTART )); then   # the interrupted install had started an agent from files that were just put back
  if [[ "${1:-}" == "--no-start" ]]; then
    print -u2 "build.sh: the agent may still be running the interrupted build; run \`mac-mcp install\` to restart it."
  else
    restart_agent || print -u2 "build.sh: could not restart the agent on the restored version."
  fi
fi
scripts/lint-blocking.sh

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
VERSION=$(tr -d '[:space:]' < VERSION)   # the one place the version is set; Sources/mac-mcp/main.swift must match (a unit test checks)
[[ "$VERSION" == [0-9]*.[0-9]*.[0-9]* ]] || { print -u2 "build.sh: VERSION holds '$VERSION', not a version like 0.1.1."; exit 1 }
BUILD="$(git rev-parse --short HEAD 2>/dev/null || echo dev)$(git diff --quiet HEAD 2>/dev/null || echo +dirty)-$(date +%Y%m%d%H%M%S)"

swift build -c release --product MacMCPAgent
swift build -c release --product mac-mcp
BIN=.build/release

# Bundle in a staging directory next to the install (same volume, so the final move is a rename). The installed
# path and bundle ID must stay fixed: permission grants follow them plus the signing identity.
mkdir -p "${APP:h}" "${CLI:h}"
STAGE=$(mktemp -d "${APP:h}/.MacMCP-stage.XXXXXX")
STAGED_APP="$STAGE/MacMCP.app"
STAGED_CLI="${CLI:h}/.mac-mcp.new.$$"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
cp "$BIN/MacMCPAgent" "$STAGED_APP/Contents/MacOS/"
cp assets/branding/MacMCP.icns "$STAGED_APP/Contents/Resources/"
cat > "$STAGED_APP/Contents/Info.plist" <<EOF
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
  print -u2 "  dedicated keychain that works unattended. The installed MacMCP was not changed."
  exit 1
}
codesign --force "${KC_ARGS[@]}" -s "$IDENTITY" -o runtime --timestamp=none --entitlements scripts/MacMCP.entitlements "$STAGED_APP" || sign_failed
cp "$BIN/mac-mcp" "$STAGED_CLI"
codesign --force "${KC_ARGS[@]}" -s "$IDENTITY" -o runtime --timestamp=none -i com.playbacksoftware.macmcp.cli "$STAGED_CLI" || sign_failed

# Verify what was built before it goes anywhere near the install. The agent can't be started here (it would take
# over the live socket), so check what launchd needs of it: a valid signature, a sound Info.plist, an arm64
# executable and the right identifier. The CLI is harmless to run, so run it.
verify_failed() {
  print -u2 "build.sh: the new build failed its checks ($1). The installed MacMCP was not changed."
  exit 1
}
codesign --verify --strict "$STAGED_APP" || verify_failed "app signature"
codesign --verify --strict "$STAGED_CLI" || verify_failed "CLI signature"
plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null || verify_failed "Info.plist"
[[ -x "$STAGED_APP/Contents/MacOS/MacMCPAgent" ]] || verify_failed "agent executable"
[[ "$(lipo -archs "$STAGED_APP/Contents/MacOS/MacMCPAgent" 2>/dev/null)" == *arm64* ]] || verify_failed "agent is not arm64"
[[ "$(codesign -dv "$STAGED_APP" 2>&1)" == *"Identifier=com.playbacksoftware.macmcp"* ]] || verify_failed "app identifier"
[[ "$("$STAGED_CLI" version 2>/dev/null)" == "mac-mcp "* ]] || verify_failed "the CLI does not run"
echo "built MacMCP $VERSION ($BUILD), signed by ${IDENTITY[1,8]}…, team $(codesign -dv "$STAGED_APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"

# A lease may have been taken while the build ran.
check_lease

# Swap in by rename. Until the new agent is healthy the old files stay next to the new ones, and an interruption
# puts them back (install_cleanup, or recover_install on the next run).
swap_in || exit 1

if [[ "${1:-}" == "--no-start" ]]; then
  commit_install   # the running agent is untouched, so there is nothing to fall back to yet
  exit 0
fi

# The agent answers a tool call (exit 2 means the tool reported a problem, which is still an answer), and again a
# couple of seconds later, so one that starts and then dies doesn't count.
agent_answers() {
  local rc
  "$CLI" call mac_doctor --timeout 10 >/dev/null 2>&1 && rc=0 || rc=$?
  (( rc == 0 || rc == 2 ))
}
agent_healthy() {
  local i
  for i in {1..20}; do
    if agent_answers; then
      sleep 2
      agent_answers && return 0
    fi
    sleep 1
  done
  return 1
}

if "$CLI" install && agent_healthy; then
  commit_install
  exit 0
fi

print -u2 "build.sh: the new agent did not start or did not answer."
if (( HAD_APP )); then
  print -u2 "          Restoring the previous MacMCP.app and restarting it."
  if revert_install; then
    if restart_agent; then
      print -u2 "          The previous version is running again. The failed build was discarded."
    else
      print -u2 "          The previous files are back, but the agent did not restart (see above). Run \`mac-mcp install\`."
    fi
  else
    print -u2 "          The previous files could not all be put back; $PREV and $CLI_PREV are kept."
  fi
else
  revert_install || true
  print -u2 "          There was no previous install to restore. See \`mac-mcp logs\` and \`mac-mcp doctor\`."
fi
exit 1
