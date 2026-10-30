#!/usr/bin/env python3
"""Measure the installed agent against MacMCPTestHost. Needs the GUI to itself.

    scripts/measure-actions.py -n 30 --json actions.json

Enable MAC_MCP_DEBUG_ACTIONS=1 in the agent's environment before starting it.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import signal
import socket
import statistics
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

HOST = "com.playbacksoftware.macmcp.testhost"
TOOLS = ("mac_click", "mac_type", "mac_key", "mac_menu")
MARKER = b"debug action_metrics "
MAX_FRAME = 16 * 1024 * 1024


class Client:
    def __init__(self, path: Path, token: str, session: str):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(90)
        self.pending = bytearray()
        self.next_id = 0
        try:
            self.sock.connect(str(path))
            self.sock.sendall(f"#mac-mcp lease={token} session={session}\n".encode())
            reply = self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "measure-actions", "version": "1"}})
            if reply.get("protocolVersion") != "2025-11-25":
                raise RuntimeError("Agent did not negotiate protocol 2025-11-25")
            self.version = reply.get("serverInfo", {}).get("version", "unknown")
            self.sock.sendall(b'{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        except BaseException:
            self.close()
            raise

    def request(self, method: str, params: dict) -> dict:
        self.next_id += 1
        request_id = self.next_id
        deadline = time.monotonic() + 90
        self.sock.settimeout(90)
        self.sock.sendall((json.dumps({"jsonrpc": "2.0", "id": request_id,
                                      "method": method, "params": params}) + "\n").encode())
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(f"{method} exceeded 90 seconds; stop and inspect the GUI before retrying")
            self.sock.settimeout(remaining)
            if b"\n" not in self.pending:
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise ConnectionError("Agent disconnected; do not mix samples across an agent restart")
                self.pending.extend(chunk)
                if len(self.pending) > MAX_FRAME:
                    raise RuntimeError("Agent response exceeded 16 MiB")
                continue
            line, _, rest = self.pending.partition(b"\n")
            self.pending = bytearray(rest)
            message = json.loads(line)
            if "id" not in message and "method" in message:
                continue
            if message.get("jsonrpc") != "2.0" or message.get("id") != request_id:
                raise RuntimeError("Unexpected JSON-RPC response")
            if "error" in message:
                raise RuntimeError(f"JSON-RPC error: {message['error']}")
            return message["result"]

    def call(self, tool: str, args: dict) -> tuple[str, float]:
        started = time.monotonic()
        result = self.request("tools/call", {"name": tool, "arguments": args})
        elapsed_ms = (time.monotonic() - started) * 1000
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        if result.get("isError"):
            raise RuntimeError(f"{tool} failed: {text}")
        return text, elapsed_ms

    def close(self) -> None:
        self.sock.close()


class Metrics:
    def __init__(self, path: Path, session: str):
        self.path, self.session = path, session
        self.file = path.open("rb")
        self.file.seek(0, os.SEEK_END)
        self.identity = os.fstat(self.file.fileno()).st_ino
        self.pending = bytearray()

    def read(self, tool: str) -> dict:
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            stat = self.path.stat()
            if stat.st_ino != self.identity or stat.st_size < self.file.tell():
                raise RuntimeError("Agent log rotated or was truncated; rerun for a consistent measurement")
            self.pending.extend(self.file.read())
            while b"\n" in self.pending:
                line, _, rest = self.pending.partition(b"\n")
                self.pending = bytearray(rest)
                if MARKER not in line:
                    continue
                record = json.loads(line.split(MARKER, 1)[1])
                if record.get("session") != self.session or record.get("tool") != tool:
                    continue
                if record.get("isError") or record.get("inFlightWalks", 0):
                    raise RuntimeError(f"{tool} metrics include an error or unfinished accessibility work")
                if record.get("walks", 0) < 1 or "settle" not in record.get("phases", {}):
                    raise RuntimeError(f"{tool} metrics have no walks or settle phase")
                return record
            time.sleep(0.02)
        raise RuntimeError("No action metrics found. Start the agent with MAC_MCP_DEBUG_ACTIONS=1; "
                           "exporting it in this shell does not enable it in an already running agent.")

    def close(self) -> None:
        self.file.close()


def ref_for(snapshot: str, role: str, label: str) -> str:
    matches = re.findall(r'^\s*(e\d+) ' + re.escape(role + ' "' + label + '"') + r'(?: |$)', snapshot, re.MULTILINE)
    if len(matches) != 1:
        raise RuntimeError(f"Expected exactly one {role} named {label!r}; reset TestHost and close its sheets and menus")
    return matches[0]


def cli_call(cli: Path, *args: str) -> str:
    reply = subprocess.run([str(cli), *args], capture_output=True, text=True, timeout=45)
    if reply.returncode:
        raise RuntimeError(reply.stderr.strip() or reply.stdout.strip() or "mac-mcp CLI failed")
    return reply.stdout.strip()


def percentile90(values: list[float]) -> float:
    return sorted(values)[math.ceil(len(values) * 0.9) - 1]


def summarize(rows: list[dict]) -> dict:
    summary = {}
    print("action       N    wall ms med/p90    walks med/p90    settle ms med/p90    unsettled")
    for tool in TOOLS:
        samples = [r for r in rows if r["tool"] == tool]
        values = {
            "wallMs": [r["wallMs"] for r in samples],
            "walks": [r["metrics"]["walks"] for r in samples],
            "settleMs": [r["metrics"]["phases"]["settle"]["milliseconds"] for r in samples],
        }
        stats = {key: {"median": statistics.median(v), "p90": percentile90(v)} for key, v in values.items()}
        stats["count"] = len(samples)
        stats["unsettled"] = sum(not r["settled"] for r in samples)
        summary[tool] = stats
        pairs = [f"{stats[k]['median']:7.1f}/{stats[k]['p90']:<7.1f}" for k in values]
        print(f"{tool:10s} {len(samples):3d}  " + "  ".join(pairs) + f"    {stats['unsettled']}")
    return summary


def main() -> int:
    home = Path.home()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-n", "--count", type=int, default=20, help="measured calls of each action (default 20)")
    parser.add_argument("--warmup", type=int, default=2, help="unmeasured rounds of all four actions (default 2)")
    parser.add_argument("--socket", type=Path, default=Path(os.environ.get("MAC_MCP_SOCKET", home / "Library/Application Support/MacMCP/mcp.sock")))
    parser.add_argument("--log", type=Path, default=home / "Library/Logs/MacMCP/agent.log")
    parser.add_argument("--cli", type=Path, default=home / ".local/bin/mac-mcp")
    parser.add_argument("--json", type=Path, help="write raw measurements and summary to this file")
    parser.add_argument("--label", default="", help="build or commit label to save with the results")
    args = parser.parse_args()
    if args.count < 1 or args.warmup < 0:
        parser.error("count must be positive and warmup must be nonnegative")

    token = os.environ.get("MAC_MCP_LEASE")
    owned = not bool(token)
    acquired = False
    client = metrics = None
    try:
        if owned:
            minutes = math.ceil((args.count + args.warmup) * 6 * 90 / 60) + 5
            token = cli_call(args.cli, "lease", "acquire", "--holder", "measure-actions",
                             "--reason", "scripts/measure-actions.py", "--minutes", str(minutes), "--pid", str(os.getpid()))
            if not re.fullmatch(r"[0-9a-f-]{36}", token):
                raise RuntimeError("Lease acquisition did not return a token")
            acquired = True
        elif not cli_call(args.cli, "lease", "status").startswith("leased by you "):
            raise RuntimeError("MAC_MCP_LEASE does not hold an active lease")
        session = "measure-" + uuid.uuid4().hex
        metrics = Metrics(args.log, session)
        client = Client(args.socket, token, session)
        client.call("mac_app", {"action": "launch", "app": HOST})
        print(f"Agent: {client.version}; {args.count} calls per action; {args.warmup} warmup rounds", flush=True)
        rows = []
        for round_index in range(args.warmup + args.count):
            for tool in TOOLS:
                if tool in ("mac_click", "mac_type"):
                    snapshot, _ = client.call("mac_snapshot", {"app": HOST})
                    if tool == "mac_click":
                        arguments = {"ref": ref_for(snapshot, "checkbox", "Bacon")}
                    else:
                        arguments = {"ref": ref_for(snapshot, "textfield", "Name"), "mode": "replace",
                                     "text": f"Measure {round_index:06d}"}
                elif tool == "mac_key":
                    arguments = {"app": HOST, "keys": "cmd+shift+h"}
                else:
                    arguments = {"app": HOST, "path": "Test > Say Hello"}
                text, wall_ms = client.call(tool, arguments)
                record = metrics.read(tool)
                if round_index >= args.warmup:
                    rows.append({"tool": tool, "wallMs": wall_ms, "settled": " · settled in " in text.split("\n", 1)[0],
                                 "metrics": record})
            print(f"Round {round_index + 1}/{args.warmup + args.count}", file=sys.stderr, flush=True)
        summary = summarize(rows)
        if args.json:
            args.json.write_text(json.dumps({"label": args.label, "agentVersion": client.version,
                "recordedAt": datetime.now(timezone.utc).isoformat(), "count": args.count, "warmup": args.warmup,
                "summary": summary, "samples": rows}, indent=2) + "\n")
        return 0
    finally:
        if client:
            client.close()
        if metrics:
            metrics.close()
        if acquired:
            try:
                cli_call(args.cli, "lease", "release", token)
            except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                print(f"Lease release failed; its owner PID expires on exit: {error}", file=sys.stderr)


if __name__ == "__main__":
    def interrupted(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("Measurement interrupted; inspect TestHost before retrying.", file=sys.stderr)
        sys.exit(130)
    except (OSError, RuntimeError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"Measurement stopped: {error}", file=sys.stderr)
        sys.exit(1)
