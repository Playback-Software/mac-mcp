#!/bin/zsh
# Phase 1 / M5 evaluation: MacOS-MCP vs MacMCP, same tasks, same model (headless Claude Code).
cd "${0:A:h}"
run() { echo "### $(date +%H:%M:%S) $*"; python3 run.py "$@"; }
# A1 (MacOS-MCP short x3) completed in the first pass: runs/20261004-214217-macos-mcp-short
run --server mac-mcp --suite short --repeat 3
run --server macos-mcp --suite long
run --server mac-mcp --suite long
run --server mac-mcp --script --suite long
run --server mac-mcp --script --suite short
echo "### $(date +%H:%M:%S) M5 DONE"
