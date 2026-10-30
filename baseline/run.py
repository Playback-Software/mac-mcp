"""Run the Phase 0a baseline tasks against an MCP server with headless Claude Code.

Usage:
    python3 run.py --server macos-mcp [--tasks N1,W2] [--model sonnet]

Each task gets a fresh `claude -p` agent whose only tools are the server's MCP
tools (no shell, no file tools). The transcript is saved as stream-json, the
outcome is checked from outside the GUI, and a summary row is written to
runs/<stamp>/summary.jsonl and summary.md.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import subprocess
import sys
import time
from contextlib import ExitStack
from datetime import datetime
from pathlib import Path

import tasks as suite

ROOT = Path(__file__).parent
MAC_MCP_CLI = Path.home() / ".local/bin/mac-mcp"
TOKEN_FILE = Path.home() / ".config/mac-mcp/claude-oauth-token"
TASK_TIMEOUT = 15 * 60

SERVERS = {
    # name: (mcp config, tool allow pattern, health-check port)
    "macos-mcp": ({"mcpServers": {"macos": {"type": "http", "url": "http://127.0.0.1:8765/mcp"}}}, "mcp__macos", 8765),
    # MacMCP through its stdio relay (same server name, so tool names are mcp__macos__mac_*).
    "mac-mcp": ({"mcpServers": {"macos": {"command": str(Path.home() / ".local/bin/mac-mcp")}}}, "mcp__macos", None),
    # Control run: stdio child of this (Background-session) process. Expected to fail.
    "macos-mcp-stdio": ({"mcpServers": {"macos": {
        "command": str(Path.home() / ".local/bin/macos-mcp"), "args": ["serve", "--transport", "stdio"],
        "env": {"ANONYMIZED_TELEMETRY": "false"}}}}, "mcp__macos", None),
}

# Non-GUI escape hatches some servers expose. Blocked so the baseline measures GUI control:
# with Shell available, an agent can pass N1 with `mkdir` without touching Finder.
DISALLOWED = ["mcp__macos__Shell", "mcp__macos__Scrape"]
# MacMCP's scripting tool is off unless --script (GUI-only runs stay comparable with the baseline).
NO_SCRIPT = ["mcp__macos__mac_script"]
SCRIPT_POLICY = {"script": {"allowed_apps": ["com.apple.TextEdit", "com.apple.finder", "com.apple.Safari"], "timeout_seconds": 30}}
# The policy's own defaults (Policy.defaultDenyApps), for when the file doesn't list deny_apps.
DEFAULT_DENY = ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable",
                "dev.warp.Warp-Preview", "dev.warp.WarpOss", "org.alacritty", "io.alacritty", "net.kovidgoyal.kitty",
                "net.kovidgoyal.kitty-quick-access", "com.github.wez.wezterm", "co.zeit.hyper",
                "com.apple.ScriptEditor2", "com.apple.Automator", "com.apple.shortcuts", "com.apple.ScriptMenuApp",
                "com.apple.AppleScriptUtility", "com.latenightsw.ScriptDebugger", "com.latenightsw.ScriptDebugger5",
                "com.latenightsw.ScriptDebugger6", "com.latenightsw.ScriptDebugger7", "com.latenightsw.ScriptDebugger8",
                "Script Debugger",
                "com.apple.Spotlight", "com.raycast.macos", "com.raycast.macos.palette", "com.raycast-x.macos",
                "com.runningwithcrayons.Alfred", "com.runningwithcrayons.Alfred-Preferences", "com.runningwithcrayons.Alfred-3",
                "com.runningwithcrayons.Alfred-Preferences-3", "com.runningwithcrayons.Alfred-2",
                "com.stairways.keyboardmaestro.editor", "com.stairways.keyboardmaestro.engine", "org.hammerspoon.Hammerspoon",
                "com.apple.keychainaccess", "com.apple.Passwords",
                "com.1password.1password", "com.1password.safari", "2BUA8C4S2C.com.1password.browser-helper",
                "com.agilebits.onepassword7", "2BUA8C4S2C.com.agilebits.onepassword7-helper", "com.agilebits.onepassword-osx",
                "com.agilebits.onepassword4", "com.bitwarden.desktop", "com.bitwarden.beta.desktop", "com.dashlane.Dashlane",
                "com.dashlane.dashlanephonefinal", "org.keepassxc.keepassxc", "org.keepassx.keepassxc",
                "com.lastpass.lastpassmacdesktop", "com.lastpass.LastPass", "com.lastpass.lastpassforsafari",
                "me.proton.pass.electron", "me.proton.pass.catalyst", "in.sinew.Enpass-Desktop.App", "in.sinew.Enpass-Desktop",
                "com.apple.systempreferences"]


def eval_policy(policy: dict, script: bool) -> dict:
    """What the suite needs on top of the person's policy, for the length of a run: the fixture site on
    127.0.0.1 (private hosts are refused by default) and System Settings (denied by default; N4 and L6 use it)."""
    policy = dict(policy)
    policy["deny_apps"] = [a for a in policy.get("deny_apps", DEFAULT_DENY) if a != "com.apple.systempreferences"]
    web = dict(policy.get("web", {}))
    web["allow_private_hosts"] = True   # not allow_hosts: a non-empty allow list would refuse every other site
    policy["web"] = web
    if script:
        policy.update(SCRIPT_POLICY)
    return policy

SYSTEM = """You are operating a macOS computer exclusively through the provided macOS MCP tools. \
You have no shell, file or web tools. Work step by step, observing the screen state with the tools \
before acting and verifying the result after acting. When you are done, end your final message with \
a single line of the form `FINAL: <answer, or DONE>`. If you cannot complete the task, end with \
`FINAL: FAILED - <short reason>`."""


def screen_locked() -> bool:
    out = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True).stdout
    return b"CGSSessionScreenIsLocked" in out


def port_open(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(1)
        return s.connect_ex(("127.0.0.1", port)) == 0


def parse_stream(path: Path) -> dict:
    tool_calls: dict[str, int] = {}
    images = 0
    result: dict = {}
    for line in path.read_text().splitlines():
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if msg.get("type") == "assistant":
            for block in msg.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    name = block["name"].split("__")[-1]
                    tool_calls[name] = tool_calls.get(name, 0) + 1
        elif msg.get("type") == "user":
            for block in msg.get("message", {}).get("content", []):
                if block.get("type") == "tool_result" and isinstance(block.get("content"), list):
                    images += sum(1 for c in block["content"] if c.get("type") == "image")
        elif msg.get("type") == "result":
            result = msg
    usage = result.get("usage", {})
    return {
        "result_text": result.get("result", ""),
        "is_error": result.get("is_error"),
        "num_turns": result.get("num_turns"),
        "duration_s": round((result.get("duration_ms") or 0) / 1000, 1),
        "cost_usd": result.get("total_cost_usd"),
        "input_tokens": (usage.get("input_tokens") or 0) + (usage.get("cache_read_input_tokens") or 0)
                        + (usage.get("cache_creation_input_tokens") or 0),
        "output_tokens": usage.get("output_tokens"),
        "models": list((result.get("modelUsage") or {}).keys()),
        "tool_calls": tool_calls,
        "images": images,
        # Waiting: MacOS-MCP's fixed-duration Wait vs MacMCP's condition-based mac_wait.
        "waits": tool_calls.get("Wait", 0) + tool_calls.get("mac_wait", 0),
    }


def parse_codex_stream(path: Path) -> dict:
    """The same summary from `codex exec --json` events: MCP tool calls, the last agent message, token usage."""
    tool_calls: dict[str, int] = {}
    images = 0
    final = ""
    usage: dict = {}
    failed = None
    for line in path.read_text().splitlines():
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind, item = msg.get("type"), msg.get("item") or {}
        if kind == "item.completed" and item.get("type") == "mcp_tool_call":
            name = item.get("tool", "?")
            tool_calls[name] = tool_calls.get(name, 0) + 1
            # Codex hands the tool's result back as JSON text inside its own content list.
            for part in (item.get("result") or {}).get("content") or []:
                try:
                    inner = json.loads(part.get("text", ""))
                except (json.JSONDecodeError, TypeError):
                    continue
                images += sum(1 for c in inner.get("content", []) if isinstance(c, dict) and c.get("type") == "image")
        elif kind == "item.completed" and item.get("type") == "agent_message":
            final = item.get("text", "")
        elif kind == "turn.completed":
            u = msg.get("usage") or {}
            for k, v in u.items():
                usage[k] = usage.get(k, 0) + (v or 0)
        elif kind in ("turn.failed", "error"):
            failed = msg.get("error") or msg.get("message") or msg
    return {
        "result_text": final,
        "is_error": bool(failed) and not final,
        "num_turns": sum(tool_calls.values()),
        "duration_s": None,
        "cost_usd": None,
        "input_tokens": usage.get("input_tokens", 0),
        "output_tokens": usage.get("output_tokens", 0),
        "models": [],
        "tool_calls": tool_calls,
        "images": images,
        "waits": tool_calls.get("mac_wait", 0),
    }


# The agent session running right now, so a stop signal can end it.
CURRENT: subprocess.Popen | None = None


def stop(signum, _frame) -> None:
    """SIGINT/SIGTERM: end the running agent session and unwind to main()'s cleanup. Installed explicitly because
    a background job started from a non-interactive shell (a script run under nohup) begins with SIGINT ignored."""
    if CURRENT and CURRENT.poll() is None:
        CURRENT.terminate()
    raise KeyboardInterrupt


# Codex runs with the shell, plugins, computer use, browsers and web search off, so MacMCP's tools are all it has
# (like `--tools ""` for Claude Code), and with MacMCP's tools pre-approved because it can't ask anyone.
CODEX_LOCKDOWN = ["--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "-s", "read-only",
                  "-c", 'approval_policy="never"', "-c", 'web_search="disabled"',
                  *[a for f in ("shell_tool", "unified_exec", "plugins", "computer_use", "apps", "browser_use",
                                "browser_use_external", "in_app_browser", "image_generation", "skill_search", "hooks",
                                "tool_suggest") for a in ("--disable", f)]]


def codex_command(task: suite.Task, server: str, model: str, effort: str, script: bool, lease: str | None) -> list[str]:
    command = SERVERS[server][0]["mcpServers"]["macos"]["command"]
    cmd = ["codex", "exec", "--json", *CODEX_LOCKDOWN, "-m", model, "-C", str(ROOT / "workdir"),
           "-c", f'model_reasoning_effort="{effort}"',
           "-c", f'mcp_servers.macos.command="{command}"',
           "-c", 'mcp_servers.macos.default_tools_approval_mode="approve"']
    if lease:
        cmd += ["-c", f'mcp_servers.macos.env={{MAC_MCP_LEASE="{lease}"}}']
    if not script:
        cmd += ["-c", 'mcp_servers.macos.disabled_tools=["mac_script"]']
    return cmd + [f"{SYSTEM}\n\n{task.prompt}"]


def run_task(task: suite.Task, server: str, out_dir: Path, model: str | None, env: dict, script: bool = False,
             run: int = 1, agent: str = "claude", effort: str = "medium") -> dict:
    config, allow, _ = SERVERS[server]
    config = json.loads(json.dumps(config))
    if server == "mac-mcp" and os.environ.get("MAC_MCP_LEASE"):
        # MCP clients pass stdio servers only a few environment variables; hand the relay the lease explicitly.
        config["mcpServers"]["macos"]["env"] = {"MAC_MCP_LEASE": os.environ["MAC_MCP_LEASE"]}
    cfg_path = out_dir / "mcp.json"
    cfg_path.write_text(json.dumps(config))
    ctx = suite.Ctx()
    task.setup(ctx)
    ctx.t0 = time.time()
    if agent == "codex":
        assert server == "mac-mcp", "the Codex agent is only wired to MacMCP"
        cmd = codex_command(task, server, model or "gpt-6-luna", effort, script, os.environ.get("MAC_MCP_LEASE"))
    else:
        cmd = ["claude", "-p", task.prompt, "--output-format", "stream-json", "--verbose",
               "--strict-mcp-config", "--mcp-config", str(cfg_path), "--tools", "", "--allowedTools", allow,
               "--disallowedTools", *DISALLOWED, *([] if script else NO_SCRIPT),
               "--setting-sources", "", "--append-system-prompt", SYSTEM,
               "--max-turns", "150" if task.id.startswith("L") else "80"]
        if model:
            cmd += ["--model", model]
    transcript = out_dir / f"{task.id}-r{run}.jsonl"
    timed_out = False
    global CURRENT
    with transcript.open("w") as f:
        CURRENT = subprocess.Popen(cmd, stdout=f, stderr=subprocess.DEVNULL if agent == "codex" else subprocess.STDOUT,
                                   stdin=subprocess.DEVNULL, cwd=ROOT / "workdir", env=env)
        try:
            CURRENT.wait(timeout=TASK_TIMEOUT * (2 if task.id.startswith("L") else 1))
        except subprocess.TimeoutExpired:
            timed_out = True
            CURRENT.kill()
            CURRENT.wait()
        finally:
            CURRENT = None
    stats = (parse_codex_stream if agent == "codex" else parse_stream)(transcript)
    if agent == "codex":
        stats["duration_s"] = round(time.time() - ctx.t0, 1)
        stats["models"] = [model or "gpt-6-luna"]
    ctx.data["transcript"] = str(transcript)   # injection checks read what the agent actually did
    try:
        passed, detail = task.check(ctx, stats["result_text"])
    except Exception as e:  # a broken check is a harness bug, not an agent failure
        passed, detail = False, f"CHECK ERROR: {e!r}"
    task.teardown(ctx)
    if "Safari" in task.apps:
        suite.safari_clean()
    suite.kill(*task.apps)
    return {"task": task.id, "server": server + ("+script" if script else ""), "run": run, "passed": passed, "detail": detail, "timed_out": timed_out,
            "final": suite.final_answer(stats["result_text"]), "wall_s": round(time.time() - ctx.t0, 1),
            **{k: v for k, v in stats.items() if k != "result_text"}}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default="macos-mcp", choices=SERVERS)
    ap.add_argument("--tasks", help="comma-separated task ids (default: all)")
    ap.add_argument("--model")
    ap.add_argument("--agent", choices=["claude", "codex"], default="claude",
                    help="codex: drive MacMCP with `codex exec` (default model gpt-6-luna); mac-mcp server only")
    ap.add_argument("--effort", default="medium", help="codex reasoning effort (low, medium, high, ...)")
    ap.add_argument("--suite", choices=["short", "long", "all", "long2", "inject", "chrome"], default="short")
    ap.add_argument("--repeat", type=int, default=1)
    ap.add_argument("--script", action="store_true", help="mac-mcp only: allow mac_script (TextEdit, Finder, Safari)")
    args = ap.parse_args()

    # The saved token works from SSH and launchd sessions; without it, claude uses this user's own login, which only
    # works from a GUI session (the keychain holding it is locked elsewhere).
    if not TOKEN_FILE.exists():
        print(f"note: no {TOKEN_FILE}; using this user's Claude Code login", file=sys.stderr)
    if screen_locked():
        sys.exit("screen is locked: unlock it via Remote Access, then rerun")
    port = SERVERS[args.server][2]
    if port and not port_open(port):
        sys.exit(f"{args.server} is not listening on 127.0.0.1:{port}")

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    # Hold the GUI lease for the whole run: GUI tests, agent reinstalls and other clients' actions are refused
    # until we're done (or this process dies). Child processes (the relay, tasks.py's CLI calls) inherit the token.
    lease = subprocess.run([str(MAC_MCP_CLI), "lease", "acquire", "--holder", "eval", "--minutes", "720",
                            "--reason", f"run.py {args.server}{'+script' if args.script else ''} {args.suite}",
                            "--pid", str(os.getpid())], capture_output=True, text=True)
    if lease.returncode != 0:
        sys.exit(f"cannot start: {lease.stderr.strip()}")
    os.environ["MAC_MCP_LEASE"] = lease.stdout.strip()
    env = {**os.environ, **({"CLAUDE_CODE_OAUTH_TOKEN": TOKEN_FILE.read_text().strip()} if TOKEN_FILE.exists() else {})}
    pool = {"short": suite.TASKS, "long": suite.LONG_TASKS, "all": suite.TASKS + suite.LONG_TASKS,
            "long2": suite.LONG_V2, "inject": suite.INJECTION, "chrome": suite.CHROME}[args.suite]
    selected = [t for t in pool if not args.tasks or t.id in args.tasks.split(",")]
    label = args.server + ("+script" if args.script else "") + (f"-{args.agent}" if args.agent != "claude" else "")
    out_dir = ROOT / "runs" / f"{datetime.now():%Y%m%d-%H%M%S}-{label}-{args.suite}"
    out_dir.mkdir(parents=True)
    (ROOT / "workdir").mkdir(exist_ok=True)

    # A fixture server left over from an interrupted run (or started by hand) would hold the port, and could be
    # running older code: stop whatever listens on it.
    holders = subprocess.run(["lsof", "-t", "-iTCP:8899", "-sTCP:LISTEN"], capture_output=True, text=True).stdout.split()
    for pid in holders:
        subprocess.run(["kill", pid], check=False)
    time.sleep(0.5)
    web = subprocess.Popen([sys.executable, str(ROOT / "webserver.py")])
    rows = []
    policies = ExitStack()
    try:
        if args.server == "mac-mcp":
            policies.enter_context(suite.temporary_policy(lambda p: eval_policy(p, args.script), cli=MAC_MCP_CLI))
        for run in range(1, args.repeat + 1):
          for task in selected:
            if screen_locked():
                print("screen locked mid-run; stopping", flush=True)
                raise KeyboardInterrupt
            print(f"[{datetime.now():%H:%M:%S}] run {run} {task.id} ...", flush=True)
            row = run_task(task, args.server, out_dir, args.model, env, script=args.script, run=run,
                           agent=args.agent, effort=args.effort)
            rows.append(row)
            with (out_dir / "summary.jsonl").open("a") as f:
                f.write(json.dumps(row) + "\n")
            calls = sum(row["tool_calls"].values())
            print(f"    {'PASS' if row['passed'] else 'FAIL'}  calls={calls} imgs={row['images']} waits={row['waits']} "
                  f"wall={row['wall_s']}s  {row['detail'][:150]}", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        web.terminate()
        try:
            policies.close()   # restore under exclusion before giving up the GUI lease
        finally:
            subprocess.run([str(MAC_MCP_CLI), "lease", "release", os.environ["MAC_MCP_LEASE"]], capture_output=True)

    lines = ["| Run | Task | Result | Tool calls | Images | Waits | Wall (s) | Tokens in/out | Detail |", "|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['run']} | {r['task']} | {'✅' if r['passed'] else '❌'} | {sum(r['tool_calls'].values())} | {r['images']} | {r['waits']} "
                     f"| {r['wall_s']} | {r['input_tokens']}/{r['output_tokens']} | {r['detail'][:120]} |")
    passed = sum(r["passed"] for r in rows)
    lines.append(f"\n**{passed}/{len(rows)} passed** — server `{label}`, suite {args.suite}, models {rows[0]['models'] if rows else []}")
    (out_dir / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"\nTranscripts: {out_dir}")


if __name__ == "__main__":
    main()
