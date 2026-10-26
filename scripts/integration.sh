#!/bin/zsh
# Runs the GUI integration tests against the installed agent while holding the GUI lease, so an eval can't start
# underneath them (and they refuse to start under someone else's).
#   scripts/integration.sh [swift test args, e.g. --filter ActionTests]
set -euo pipefail
cd "${0:A:h}/.."
source "${0:A:h}/toolchain.sh"
CLI="$HOME/.local/bin/mac-mcp"
export MAC_MCP_LEASE=$("$CLI" lease acquire --holder integration-tests --reason "swift test" --minutes 30 --pid $$)
trap '"$CLI" lease release "$MAC_MCP_LEASE" >/dev/null' EXIT
MAC_MCP_INTEGRATION=1 swift test --filter IntegrationTests "$@"
