"""Second client for the M10 evaluation: the Claude Agent SDK (Python) driving MacMCP, locally or over SSH.

    uv run --with claude-agent-sdk python sdk_client.py [--tasks W2,N2,L4] [--ssh user@host] [--model …] [--repeat N]

It runs suite tasks (setup → agent → check, same checks as run.py), but through the Agent SDK instead of the
`claude -p` CLI, with MacMCP as an MCP server reached through the stdio relay:
- local:  ~/.local/bin/mac-mcp
- remote: ssh <host> /Users/<you>/.local/bin/mac-mcp   (run this script on another machine; checks then need the
          fixtures and files on the Mac, so remote mode is for spot checks)

Results go to runs/<timestamp>-sdk-<label>/summary.jsonl in the same format as run.py, so compare.py includes them.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path

from claude_agent_sdk import AssistantMessage, ClaudeAgentOptions, ResultMessage, ToolUseBlock, query

import tasks as suite

ROOT = Path(__file__).parent
CLI = Path.home() / ".local/bin/mac-mcp"
TOKEN_FILE = Path.home() / ".config/mac-mcp/claude-oauth-token"
SYSTEM = ("You control this Mac through the macos MCP tools only. Work step by step and verify results. "
          "End your reply with a line 'FINAL: <answer or DONE>'.")


async def run_one(task: suite.Task, server_cmd: list[str], model: str | None, transcript: Path) -> dict:
    ctx = suite.Ctx()
    task.setup(ctx)
    ctx.t0 = time.time()
    env = {"MAC_MCP_LEASE": os.environ.get("MAC_MCP_LEASE", "")}
    options = ClaudeAgentOptions(
        mcp_servers={"macos": {"type": "stdio", "command": server_cmd[0], "args": server_cmd[1:], "env": env}},
        allowed_tools=["mcp__macos"],
        disallowed_tools=["mcp__macos__mac_script", "Bash", "Read", "Write", "Edit", "WebFetch", "WebSearch"],
        system_prompt=SYSTEM,
        model=model,
        max_turns=150 if task.id.startswith("L") else 80,
        setting_sources=[],
        permission_mode="bypassPermissions",
    )
    calls: dict[str, int] = {}
    result_text, usage, cost = "", {}, None
    with transcript.open("w") as log:
        try:
            async with asyncio.timeout(1200 if task.id.startswith("L") else 600):
                async for message in query(prompt=task.prompt, options=options):
                    log.write(json.dumps(message, default=lambda o: getattr(o, "__dict__", str(o))) + "\n")
                    if isinstance(message, AssistantMessage):
                        for block in message.content:
                            if isinstance(block, ToolUseBlock):
                                name = block.name.replace("mcp__macos__", "")
                                calls[name] = calls.get(name, 0) + 1
                    elif isinstance(message, ResultMessage):
                        result_text, usage, cost = message.result or "", message.usage or {}, message.total_cost_usd
        except TimeoutError:
            result_text = ""
    ctx.data["transcript"] = str(transcript)
    try:
        passed, detail = task.check(ctx, result_text)
    except Exception as e:
        passed, detail = False, f"CHECK ERROR: {e!r}"
    task.teardown(ctx)
    suite.kill(*task.apps)
    return {"task": task.id, "server": "mac-mcp", "client": "agent-sdk", "passed": passed, "detail": detail,
            "final": suite.final_answer(result_text), "wall_s": round(time.time() - ctx.t0, 1),
            "tool_calls": calls, "images": calls.get("mac_screenshot", 0),
            "waits": calls.get("mac_wait", 0), "input_tokens": usage.get("input_tokens", 0)
            + usage.get("cache_read_input_tokens", 0) + usage.get("cache_creation_input_tokens", 0),
            "output_tokens": usage.get("output_tokens", 0), "models": [model] if model else [], "cost_usd": cost}


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tasks", default="N2,W2,L4")
    ap.add_argument("--ssh", help="user@host: reach MacMCP over SSH instead of the local relay")
    ap.add_argument("--model")
    ap.add_argument("--repeat", type=int, default=1)
    args = ap.parse_args()
    os.environ.setdefault("CLAUDE_CODE_OAUTH_TOKEN", TOKEN_FILE.read_text().strip() if TOKEN_FILE.exists() else "")
    server = ["ssh", args.ssh, str(CLI)] if args.ssh else [str(CLI)]
    pool = {t.id: t for t in suite.TASKS + suite.LONG_TASKS + suite.LONG_V2 + suite.INJECTION + suite.CHROME}
    selected = [pool[t] for t in args.tasks.split(",")]
    lease = subprocess.run([str(CLI), "lease", "acquire", "--holder", "eval-sdk", "--minutes", "360",
                            "--reason", "sdk_client.py", "--pid", str(os.getpid())], capture_output=True, text=True)
    if lease.returncode != 0:
        sys.exit(f"cannot start: {lease.stderr.strip()}")
    os.environ["MAC_MCP_LEASE"] = lease.stdout.strip()
    for pid in subprocess.run(["lsof", "-t", "-iTCP:8899", "-sTCP:LISTEN"], capture_output=True, text=True).stdout.split():
        subprocess.run(["kill", pid])
    time.sleep(0.5)
    web = subprocess.Popen([sys.executable, str(ROOT / "webserver.py")])
    out = ROOT / "runs" / f"{datetime.now():%Y%m%d-%H%M%S}-sdk-{'ssh' if args.ssh else 'local'}-short"
    out.mkdir(parents=True)
    try:
        for run in range(1, args.repeat + 1):
            for task in selected:
                print(f"[{datetime.now():%H:%M:%S}] run {run} {task.id} …", flush=True)
                row = await run_one(task, server, args.model, out / f"{task.id}-r{run}.jsonl")
                row["run"] = run
                with (out / "summary.jsonl").open("a") as f:
                    f.write(json.dumps(row) + "\n")
                print(f"    {'PASS' if row['passed'] else 'FAIL'}  calls={sum(row['tool_calls'].values())} "
                      f"wall={row['wall_s']}s  {row['detail'][:150]}", flush=True)
    finally:
        web.terminate()
        subprocess.run([str(CLI), "lease", "release", os.environ["MAC_MCP_LEASE"]], capture_output=True)


if __name__ == "__main__":
    asyncio.run(main())
