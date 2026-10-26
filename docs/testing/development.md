# Development and testing

```bash
swift test --skip IntegrationTests                       # unit tests (no permissions needed)
scripts/build.sh && scripts/build-testhost.sh            # install the agent and the TestHost fixture app
scripts/integration.sh                                   # end-to-end against TestHost, holding the GUI lease
scripts/soak.py [--legacy]                               # 2,000 mixed calls + a frozen app + an agent restart
scripts/protocol-probe.py OUT.json                       # record the agent's answers to edge-case protocol messages
```

`build.sh` runs `scripts/lint-blocking.sh` (no thread-blocking calls in agent code) and refuses to replace the agent
while someone else holds the GUI lease.

`TestHost` is a small SwiftUI app with known controls (form fields, a secure field, a 60-row list, a sheet, an alert).
`macmcp-testhost://sheet|alert|dismiss|reset` URLs change its state without clicks.

Run `swift` with full Xcode selected (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, or
`xcode-select -s`): TestHost uses SwiftUI macros that the Command Line Tools can't build. The scripts select Xcode
themselves.

## Agent task suite

`baseline/` runs real agents against MacMCP: each task gets a fresh headless Claude Code (`claude -p`) whose only
tools are the server's, and the outcome is checked from outside the GUI. It uses your Claude Code login, or a
`claude setup-token` token saved with `baseline/save-token.zsh` (needed over SSH). It holds the GUI lease for the
run and writes results to `baseline/runs/`.

```bash
cd baseline
python3 run.py --server mac-mcp --suite short --repeat 3 --model claude-haiku-5-5
python3 run.py --server mac-mcp --agent codex --suite short --repeat 3
python3 compare.py                                       # summarise runs
```

`--agent codex` drives MacMCP with `codex exec` instead (default model `gpt-6-luna`, `--effort medium`). Codex runs
with its shell, plugins, computer use, browsers and web search switched off and your Codex config ignored, so
MacMCP's tools are all it has, as with Claude Code.

Suites: `short` (14 everyday tasks), `long` (4) and `long2` (8) multi-app workflows, `inject` (2 pages with
prompt-injection text the agent must not obey) and `chrome` (3 tasks in Google Chrome).
