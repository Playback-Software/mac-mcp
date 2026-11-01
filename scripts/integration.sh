#!/bin/zsh
# Runs the GUI integration tests against the installed agent while holding the GUI lease, so an eval can't start
# underneath them (and they refuse to start under someone else's).
#   scripts/integration.sh [swift test args, e.g. --filter ActionTests]
set -euo pipefail
cd "${0:A:h}/.."
source "${0:A:h}/toolchain.sh"
CLI="$HOME/.local/bin/mac-mcp"
agent_pause_status=$("$CLI" status)
if [[ "$agent_pause_status" != *"Agents are running (not paused)."* ]]; then
  print -u2 -- "Cannot run integration tests: the agent is paused or its pause state is unavailable."
  print -u2 -- "$agent_pause_status"
  print -u2 -- 'Check `mac-mcp status`; run `mac-mcp resume` in Terminal when you are ready, then retry.'
  exit 1
fi
export MAC_MCP_LEASE=$("$CLI" lease acquire --holder integration-tests --reason "swift test" --minutes 30 --pid $$)
trap '"$CLI" lease release "$MAC_MCP_LEASE" >/dev/null' EXIT
# swift test runs what any --filter matches, so a filter given here replaces the default instead of adding to it.
filter=(--filter IntegrationTests)
[[ " $* " == *" --filter "* ]] && filter=()
MAC_MCP_INTEGRATION=1 swift test "${filter[@]}" "$@"
