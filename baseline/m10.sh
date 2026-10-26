#!/bin/zsh
# M10 evaluation. Logs to runs/m10.log.
cd "${0:A:h}"
HAIKU=claude-haiku-5-5   # the 2026-10-05 run used claude-haiku-4-5-20251001
SONNET=claude-sonnet-5-5
step() { echo "### $(date +%H:%M:%S) $*"; python3 run.py "$@"; }
# MacMCP, Opus: the new suites, 3 runs each
step --server mac-mcp --suite long2 --repeat 3
step --server mac-mcp --suite inject --repeat 3
step --server mac-mcp --suite chrome --repeat 3
# Cheaper models on MacMCP: the 14-task suite, 3 runs each
step --server mac-mcp --suite short --repeat 3 --model $SONNET
step --server mac-mcp --suite short --repeat 3 --model $HAIKU
# Baseline (trimmed): MacOS-MCP once on the new suites, and with Haiku on the short suite
step --server macos-mcp --suite long2
step --server macos-mcp --suite inject
step --server macos-mcp --suite chrome
step --server macos-mcp --suite short --repeat 3 --model $HAIKU
# Second client: the Agent SDK through the local relay
echo "### $(date +%H:%M:%S) agent-sdk"; uv run --quiet --with claude-agent-sdk python sdk_client.py --tasks N2,W2,L4 --repeat 2
echo "### $(date +%H:%M:%S) M10 DONE"
