#!/usr/bin/env python3
"""Soak and chaos test for the installed MacMCP agent (M6). Drives MacMCPTestHost; needs the GUI to itself.

    scripts/soak.py [--calls 2000] [--workers 3] [--no-chaos]

Phases:
  1. load:     several concurrent connections making a mix of snapshots, large screenshots, clicks, typing, keys,
               scrolls, menu picks and waits (concurrent responses of very different sizes are what broke the
               swift-sdk transport in M5)
  2. hang:     TestHost is frozen with SIGSTOP for 20 s while the load continues; calls may fail but must return
  3. restart:  the agent is restarted under a live relay session; the session must survive

Pass criteria: no call runs past its deadline (+10 s slack), every response is well-formed, and the agent never
restarts except in phase 3 (no watchdog exits).
Holds the GUI lease for the whole run.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from collections import Counter, defaultdict
from pathlib import Path

HOME = Path.home()
CLI = HOME / ".local/bin/mac-mcp"
SOCKET = Path(os.environ.get("MAC_MCP_SOCKET", HOME / "Library/Application Support/MacMCP/mcp.sock"))
AGENT_LOG = HOME / "Library/Logs/MacMCP/agent.log"
HOST = "MacMCPTestHost"
HOST_ID = "com.playbacksoftware.macmcp.testhost"
MODERN = True  # set from --legacy in main()
SLACK = 10  # seconds beyond a tool's deadline before a call counts as hung

# Deadlines the agent declares (ToolSpec.deadline + dispatcher slack), for judging hangs from outside. Tools that take
# the action lock may wait up to 30 s for it, then hold it up to 20 s.
LOCKED = {"mac_click", "mac_type", "mac_key", "mac_scroll", "mac_drag", "mac_menu", "mac_script"}
DEADLINES = {"mac_wait": 15 + 5, "mac_script": 30 + 35 + 10}
DEFAULT_DEADLINE = 35
LOCKED_DEADLINE = 30 + 20 + 10


class Client:
    """One MCP session over the agent's Unix socket (or over a `mac-mcp` relay subprocess)."""

    def __init__(self, name: str, lease: str | None, relay: bool = False, modern: bool = False):
        self.lock = threading.Lock()
        self.next_id = 1
        # 2026-07-28: no handshake; every request carries its protocol version and client details in _meta.
        self.meta = {"io.modelcontextprotocol/protocolVersion": "2026-07-28",
                     "io.modelcontextprotocol/clientInfo": {"name": name, "version": "soak"},
                     "io.modelcontextprotocol/clientCapabilities": {}} if modern else None
        if relay:
            env = dict(os.environ, MAC_MCP_LEASE=lease or "")
            self.proc = subprocess.Popen([str(CLI)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, env=env)
            self.wfile, self.rfile = self.proc.stdin, self.proc.stdout
        else:
            self.proc = None
            self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.sock.connect(str(SOCKET))
            self.rfile = self.sock.makefile("rb")
            self.wfile = self.sock.makefile("wb")
            if lease:
                self.wfile.write(f"#mac-mcp lease={lease}\n".encode())
        if not modern:
            self.request("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                                        "clientInfo": {"name": name, "version": "soak"}})
            self.notify("notifications/initialized")

    def notify(self, method: str) -> None:
        self.wfile.write((json.dumps({"jsonrpc": "2.0", "method": method}) + "\n").encode())
        self.wfile.flush()

    def request(self, method: str, params: dict) -> dict:
        with self.lock:
            rid = self.next_id
            self.next_id += 1
            if self.meta:
                params = {**params, "_meta": self.meta}
            self.wfile.write((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
            self.wfile.flush()
            while True:
                line = self.rfile.readline()
                if not line:
                    raise ConnectionError("connection closed")
                msg = json.loads(line)  # raises on a corrupted (interleaved) line
                if msg.get("id") == rid:
                    return msg
                if "id" in msg and "method" not in msg:
                    raise ValueError(f"response for id {msg.get('id')} while waiting for {rid}")

    def call(self, tool: str, args: dict | None = None) -> tuple[bool, str, float]:
        start = time.monotonic()
        msg = self.request("tools/call", {"name": tool, "arguments": args or {}})
        took = time.monotonic() - start
        if "error" in msg:
            return False, f"JSON-RPC error: {msg['error'].get('message')}", took
        result = msg["result"]
        text = "\n".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")
        return not result.get("isError", False), text, took

    def close(self) -> None:
        try:
            if self.proc:
                self.proc.stdin.close()
                self.proc.wait(timeout=5)
            else:
                self.sock.close()
        except Exception:
            pass


class Stats:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.calls = 0
        self.ok = Counter()
        self.errors = Counter()
        self.error_samples: dict[str, str] = {}
        self.max_took = defaultdict(float)
        self.hangs: list[str] = []
        self.broken: list[str] = []

    def record(self, phase: str, tool: str, ok: bool, text: str, took: float) -> None:
        with self.lock:
            self.calls += 1
            self.max_took[tool] = max(self.max_took[tool], took)
            limit = DEADLINES.get(tool, LOCKED_DEADLINE if tool in LOCKED else DEFAULT_DEADLINE)
            if took > limit + SLACK:
                self.hangs.append(f"[{phase}] {tool} took {took:.1f} s: {text[:120]}")
            key = f"{phase}:{tool}"
            if ok:
                self.ok[key] += 1
            else:
                kind = re.sub(r"\b[ec]\d+\b", "<ref>", text.split("\n")[0])[:90]
                self.errors[f"{key}: {kind}"] += 1


def ref_of(snapshot: str, pattern: str) -> str | None:
    for line in snapshot.splitlines():
        m = re.match(r"\s*(e\d+) (.*)", line)
        if m and re.search(pattern, m.group(2)):
            return m.group(1)
    return None


def host_pid() -> int | None:
    out = subprocess.run(["pgrep", "-f", "MacMCPTestHost.app/Contents/MacOS"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def agent_pid() -> int | None:
    out = subprocess.run([str(CLI), "status"], capture_output=True, text=True).stdout
    m = re.search(r"pid (\d+)", out)
    return int(m.group(1)) if m else None


def worker(n: int, lease: str, stop: threading.Event, phase: list[str], stats: Stats, budget: list[int]) -> None:
    rng = random.Random(n)
    try:
        c = Client(f"soak-{n}", lease, modern=MODERN)
    except Exception as e:
        stats.broken.append(f"worker {n} could not connect: {e}")
        return
    snap = ""
    while not stop.is_set():
        with stats.lock:
            if budget[0] <= 0:
                return
            budget[0] -= 1
        p = phase[0]
        roll = rng.random()
        try:
            if roll < 0.25 or not snap:
                tool, args = "mac_snapshot", {"app": HOST}
            elif roll < 0.35:
                tool, args = "mac_screenshot", {"app": HOST, "max_edge": 1600}  # ~1–2 MB responses
            elif roll < 0.50:
                label = rng.choice(['checkbox "Bacon"', 'checkbox "Mushroom"', 'button "Submit"'])
                ref = ref_of(snap, re.escape(label))
                tool, args = ("mac_click", {"ref": ref}) if ref else ("mac_snapshot", {"app": HOST})
            elif roll < 0.62:
                ref = ref_of(snap, r'^textfield "Name"')
                tool, args = ("mac_type", {"ref": ref, "text": f"soak {n} {rng.randint(0, 9999)}"}) if ref \
                    else ("mac_snapshot", {"app": HOST})
            elif roll < 0.70:
                tool, args = "mac_key", {"keys": "tab", "app": HOST}
            elif roll < 0.78:
                tool, args = "mac_scroll", {"app": HOST, "direction": rng.choice(["up", "down"]), "amount": 3}
            elif roll < 0.84:
                tool, args = "mac_menu", {"app": HOST, "path": "Test > Say Hello"}
            elif roll < 0.92:
                tool, args = "mac_wait", {"app": HOST, "until": "settled", "timeout": 5}
            elif roll < 0.96:
                tool, args = "mac_doctor", {}
            else:
                tool, args = "mac_app", {"action": "list"}
            ok, text, took = c.call(tool, args)
            p = "hang" if "hang" in (p, phase[0]) else p   # the hang overlapped this call
            if tool == "mac_snapshot" and ok:
                snap = text
            stats.record(p, tool, ok, text, took)
        except Exception as e:
            stats.broken.append(f"[{p}] worker {n} {type(e).__name__}: {e}")
            try:
                c.close()
                c = Client(f"soak-{n}", lease, modern=MODERN)
            except Exception as e2:
                stats.broken.append(f"worker {n} could not reconnect: {e2}")
                return
    c.close()


def restart_phase(lease: str, stats: Stats) -> None:
    """A relay session keeps working across an agent restart (one call may be cut off with an error)."""
    c = Client("soak-relay", lease, relay=True)
    ok, _, _ = c.call("mac_snapshot", {"app": HOST})
    stats.record("restart", "mac_snapshot", ok, "", 0)
    env = dict(os.environ, MAC_MCP_LEASE=lease)
    subprocess.run([str(CLI), "restart"], env=env, capture_output=True)
    results = []
    for _ in range(5):
        try:
            ok, text, took = c.call("mac_snapshot", {"app": HOST})
            results.append(ok)
            stats.record("restart", "mac_snapshot", ok, text, took)
        except Exception as e:
            stats.broken.append(f"[restart] relay session ended: {type(e).__name__}: {e}")
            break
    if not any(results[-3:]):
        stats.broken.append(f"[restart] relay session didn't recover after the restart: {results}")
    c.close()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--calls", type=int, default=2000)
    ap.add_argument("--workers", type=int, default=3)
    ap.add_argument("--no-chaos", action="store_true")
    ap.add_argument("--legacy", action="store_true", help="use the 2025-11-25 initialize handshake (default: 2026-07-28)")
    args = ap.parse_args()
    global MODERN
    MODERN = not args.legacy

    lease = subprocess.run([str(CLI), "lease", "acquire", "--holder", "soak", "--reason", "scripts/soak.py",
                            "--minutes", "90", "--pid", str(os.getpid())], capture_output=True, text=True)
    if lease.returncode != 0:
        print(lease.stderr.strip(), file=sys.stderr)
        return 1
    token = lease.stdout.strip()
    log_start = AGENT_LOG.stat().st_size if AGENT_LOG.exists() else 0
    pid_before = agent_pid()
    stats = Stats()
    started = time.monotonic()
    try:
        env = dict(os.environ, MAC_MCP_LEASE=token)
        subprocess.run([str(CLI), "call", "mac_app", json.dumps({"action": "launch", "app": HOST_ID,
                       "open": "macmcp-testhost://reset"})], env=env, capture_output=True)
        # Let TestHost settle first: right after the integration tests it can still be recovering (focus, a frozen
        # spell), and the first typing then lands nowhere.
        time.sleep(2)
        subprocess.run([str(CLI), "call", "mac_wait", json.dumps({"app": HOST, "until": "settled", "timeout": 10})],
                       env=env, capture_output=True)
        stop, phase, budget = threading.Event(), ["load"], [args.calls]
        threads = [threading.Thread(target=worker, args=(i, token, stop, phase, stats, budget), daemon=True)
                   for i in range(args.workers)]
        for t in threads:
            t.start()
        if not args.no_chaos:
            while budget[0] > args.calls // 2 and any(t.is_alive() for t in threads):
                time.sleep(1)
            pid = host_pid()
            if pid:
                print(f"[hang] SIGSTOP TestHost ({pid}) for 20 s", flush=True)
                phase[0] = "hang"
                os.kill(pid, signal.SIGSTOP)
                try:
                    time.sleep(20)
                finally:
                    os.kill(pid, signal.SIGCONT)
                phase[0] = "load"
        last = time.monotonic()
        while any(t.is_alive() for t in threads):
            time.sleep(1)
            if time.monotonic() - last > 30:
                last = time.monotonic()
                print(f"  {stats.calls} calls, {len(stats.hangs)} hangs, {len(stats.broken)} broken", flush=True)
        if not args.no_chaos:
            print("[restart] restarting the agent under a relay session", flush=True)
            pid_before = None  # a restart is expected from here on
            restart_phase(token, stats)
    finally:
        subprocess.run([str(CLI), "lease", "release", token], capture_output=True)

    log = AGENT_LOG.read_text(errors="replace")[log_start:] if AGENT_LOG.exists() else ""
    watchdog = [l for l in log.splitlines() if "WATCHDOG" in l]
    restarted = pid_before is not None and agent_pid() != pid_before
    minutes = (time.monotonic() - started) / 60

    print(f"\n{stats.calls} calls in {minutes:.1f} min: {sum(stats.ok.values())} ok, {sum(stats.errors.values())} errors")
    print("slowest per tool: " + ", ".join(f"{t} {s:.1f}s" for t, s in sorted(stats.max_took.items(), key=lambda x: -x[1])))
    if stats.errors:
        print("errors (expected some during the hang phase):")
        for k, v in stats.errors.most_common(15):
            print(f"  {v:4d}  {k}")
    problems = stats.hangs + stats.broken + watchdog + (["agent restarted unexpectedly"] if restarted else [])
    hang_phase_ok = sum(v for k, v in stats.ok.items() if k.startswith("hang:"))
    print(f"hang phase: {hang_phase_ok} calls still succeeded (other apps, cached reads)")
    if problems:
        print(f"\nFAIL: {len(problems)} problem(s)")
        for p in problems[:30]:
            print("  " + p)
        return 1
    print("\nPASS: no hangs, no corrupted responses, no unexpected agent restarts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
