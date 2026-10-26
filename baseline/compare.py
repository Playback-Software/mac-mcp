"""Compare evaluation runs: python3 compare.py [--since YYYYMMDD-HHMMSS] [--out report.md]

Groups every runs/*/summary.jsonl by configuration (server, +script) and suite, then prints:
- per configuration: pass rate and mean tool calls / screenshots / waits / input tokens / wall time per task run
- per task: passes and mean calls for each configuration side by side
- the Phase 1 targets (short suite, MacMCP GUI-only vs MacOS-MCP)
"""

from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path
from statistics import mean

ROOT = Path(__file__).parent


def load(since: str | None) -> list[dict]:
    rows = []
    for d in sorted((ROOT / "runs").glob("*/")):
        if d.name.startswith("aborted-") or (since and d.name[:15] < since):
            continue
        f = d / "summary.jsonl"
        if not f.exists():
            continue
        suite = d.name.rstrip("/").rsplit("-", 1)[-1]   # …-mac-mcp-long2 → long2
        if suite not in ("short", "long", "long2", "inject", "chrome", "all"):
            suite = "short"
        for line in f.read_text().splitlines():
            r = json.loads(line)
            if r.get("excluded"):   # invalidated by outside interference; the reason is recorded in the row
                continue
            r["suite"] = suite
            r["calls"] = sum(r["tool_calls"].values())
            # Runs with another model (M10: Sonnet, Haiku) are their own configuration.
            models = [m for m in r.get("models", []) if not m.startswith("claude-haiku") or len(r.get("models", [])) == 1]
            model = next((m for m in models if "opus" not in m), None)
            r["config"] = r["server"] + (f" · {model}" if model else "") + (f" · {r['client']}" if r.get("client") else "")
            rows.append(r)
    return rows


def fmt(x: float, digits: int = 1) -> str:
    return f"{x:,.{digits}f}" if isinstance(x, float) else f"{x:,}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--since")
    ap.add_argument("--out")
    args = ap.parse_args()
    rows = load(args.since)
    out: list[str] = []

    groups: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for r in rows:
        groups[(r["suite"], r["config"])].append(r)

    for suite in ["short", "long", "long2", "inject", "chrome"]:
        configs = sorted({s for (su, s) in groups if su == suite})
        if not configs:
            continue
        out.append(f"## {suite.capitalize()} suite\n")
        out.append("| Configuration | Passed | Calls / task | Screenshots / task | Waits / task | Input tokens / task | Wall s / task |")
        out.append("|---|---|---|---|---|---|---|")
        for c in configs:
            g = groups[(suite, c)]
            out.append(f"| `{c}` | {sum(r['passed'] for r in g)}/{len(g)} | {fmt(mean(r['calls'] for r in g))} | "
                       f"{fmt(mean(r['images'] for r in g))} | {fmt(mean(r.get('waits', 0) for r in g))} | "
                       f"{fmt(mean(r['input_tokens'] for r in g), 0)} | {fmt(mean(r['wall_s'] for r in g))} |")
        out.append("")
        tasks = sorted({r["task"] for r in rows if r["suite"] == suite}, key=lambda t: (t[0], int(t[1:])))
        out.append("| Task | " + " | ".join(f"`{c}` passed · calls · imgs" for c in configs) + " |")
        out.append("|---|" + "---|" * len(configs))
        for t in tasks:
            cells = []
            for c in configs:
                g = [r for r in groups[(suite, c)] if r["task"] == t]
                cells.append(f"{sum(r['passed'] for r in g)}/{len(g)} · {fmt(mean(r['calls'] for r in g))} · {fmt(mean(r['images'] for r in g))}"
                             if g else "–")
            out.append(f"| {t} | " + " | ".join(cells) + " |")
        out.append("")

    base, ours = groups.get(("short", "macos-mcp")), groups.get(("short", "mac-mcp"))
    if base and ours:
        out.append("## Phase 1 targets (short suite, MacMCP GUI-only vs MacOS-MCP, per task run)\n")
        out.append("| Metric | MacOS-MCP | MacMCP | Change | Target | Met? |")
        out.append("|---|---|---|---|---|---|")
        def per(g, k): return mean(r[k] for r in g)
        for label, key, target in [("Tool calls", "calls", -40), ("Screenshots", "images", -65),
                                   ("Input tokens", "input_tokens", -40), ("Wall time (s)", "wall_s", -30)]:
            b, o = per(base, key), per(ours, key)
            change = (o - b) / b * 100 if b else 0.0
            out.append(f"| {label} | {fmt(b)} | {fmt(o)} | {change:+.0f}% | {target}% | {'✅' if change <= target else '❌'} |")
        bw, ow = per(base, "waits"), per(ours, "waits")
        out.append(f"| Fixed waits | {fmt(bw)} | {fmt(ow)} (condition waits) | – | 0 fixed | {'✅' if ours else ''} |")
        bp = sum(r["passed"] for r in base) / len(base) * 100
        op = sum(r["passed"] for r in ours) / len(ours) * 100
        out.append(f"| Pass rate | {bp:.0f}% | {op:.0f}% | {op - bp:+.0f} pts | ≥ baseline | {'✅' if op >= bp else '❌'} |")
        out.append("")

    text = "\n".join(out)
    print(text)
    if args.out:
        Path(args.out).write_text(text + "\n")


if __name__ == "__main__":
    main()
