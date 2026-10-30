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

## Action measurements

`scripts/measure-actions.py` measures the installed agent against the installed MacMCPTestHost. Run it only when
you own the GUI. It takes a process-bound GUI lease and releases it on exit, or uses `MAC_MCP_LEASE` when you
already hold a lease. It launches TestHost, toggles Bacon, replaces Name with synthetic text, sends the Test menu's
keyboard shortcut, and chooses Test > Say Hello. It leaves that test state in place. Close TestHost's sheets,
alerts and menus and reset it before each run; keep its window size, position, and the rest of the desktop the same.
Handle any macOS prompts yourself. The harness stops on refusals and errors.

Enable diagnostics in the **agent's** environment before starting it. For an agent managed by the GUI LaunchAgent:

```bash
launchctl setenv MAC_MCP_DEBUG_ACTIONS 1
mac-mcp restart
scripts/measure-actions.py -n 30 --warmup 2 --label before --json actions-before.json
# Install the comparison build, then run the same measurement:
scripts/measure-actions.py -n 30 --warmup 2 --label after --json actions-after.json
launchctl unsetenv MAC_MCP_DEBUG_ACTIONS
mac-mcp restart
```

Exporting the flag in the measurement shell alone does not affect an agent that is already running. No config
file edits are needed. For an agent started another way, set `MAC_MCP_DEBUG_ACTIONS=1` in that process's environment.
The harness does not install, restart or reconfigure the agent. Both builds must include the instrumentation;
commit `50edfc1` is the instrumented baseline before walk reuse. The harness from the final checkout also works
against that build. Keep build configuration and policy rate limits identical between runs.

Each measured round runs one click, type, key and menu call. Setup, fresh target snapshots, log reading and the
warmup rounds are excluded from wall time. The table prints the median and nearest-rank p90 of wall milliseconds,
actual accessibility walks, and settle milliseconds for each action, plus the number of unsettled responses.
Wall time covers the whole socket tool exchange, including lock waits, policy checks and audit work. Use a larger
`-n` for steadier percentiles. `--json` saves every measured call, its counters, and the summary for comparison.
The two-round warmup allows accessibility enabling and settle calibration to finish before measurement.

With the flag enabled, the agent emits one `debug action_metrics {…}` JSON line per mutating `mac_*` call to
`~/Library/Logs/MacMCP/agent.log`. It records total walks, nodes, walk milliseconds, in-flight walks at return, and
wall milliseconds by phase (`guards`, `lock_wait`, `before`, `resolve`, `act`, `settle`, `after`, `report`).
`guards` includes admission, rate limiting and other time outside the named phases; input and route guards inside
the action body belong to `act`. Walks on dedicated guard threads keep their caller's phase. `reusedWalks` counts
walks supplied from settle rather than performed again (absent in the baseline). No tool arguments or screen text
are recorded. The random socket session id correlates each measurement with its log record, excluding other
clients. Missing metrics, log rotation, unfinished walks or disconnections stop the run instead of mixing data.

Paths can be overridden with `--cli`, `--socket` (also `MAC_MCP_SOCKET`) and `--log`; the defaults use the current
user's installed agent. The CLI and socket must address the same installation and GUI lease store. This is a GUI
benchmark for the parent/operator, not part of unit tests or a command to run in an implementation worktree.

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
