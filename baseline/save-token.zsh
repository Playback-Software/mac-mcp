#!/bin/zsh
# Store the Claude Code OAuth token (from `claude setup-token`) for headless baseline runs.
set -euo pipefail
F=$HOME/.config/mac-mcp/claude-oauth-token
read -s "TOKEN?Paste the token printed by 'claude setup-token' (hidden): "; echo
TOKEN=${TOKEN//[[:space:]]/}   # a wrapped copy from a narrow terminal picks up line breaks
[[ "$TOKEN" == sk-ant-oat* && ${#TOKEN} -gt 60 ]] || { echo "that doesn't look like a setup-token token (expected sk-ant-oat..., 60+ chars); nothing saved"; exit 1; }
( umask 077; print -rn -- "$TOKEN" > "$F" )
unset TOKEN
echo "TOKEN-SAVED to $F"
