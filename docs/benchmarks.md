# Benchmarks

How well an agent gets real work done on a Mac through MacMCP, and what it costs. The numbers come from the agent
task suite in `baseline/` ([Development and testing](testing/development.md#agent-task-suite)), run on one Mac. They
are one run per task, so a few calls or seconds either way is noise.

## Setup

- **Agent:** Claude Code, headless, with Claude Haiku 5.5, the smallest current Claude model. Only MacMCP's tools are
  available to it.
- **Mac:** MacBook with Apple silicon, macOS 27.2, built-in Retina display. The default policy, with no
  AppleScript allowed.
- **Tasks:** 31 tasks across Finder, TextEdit, Safari, Chrome, Calculator, Activity Monitor, System Settings, Notes,
  VS Code, Xcode, a native test app and a local web app. Two of them hide instructions in a web page or document
  (prompt injection). Each task is checked by a script that inspects the result (files, app state, what the web
  server received), not by the agent's own report.

## Results: MacMCP 0.1.2

All 31 tasks passed.

| | 0.1.1 | 0.1.2 |
| --- | ---: | ---: |
| Tasks passed | 31 / 31 | 31 / 31 |
| Tool calls per task (mean / median) | 14.2 / 12 | 12.5 / 12 |
| Screenshots, all tasks | 54 | 30 |
| Input tokens per task (mean) | 229k | 177k |
| Time per task (median) | 27 s | 25 s |
| Cost of the whole suite | $0.17 | $0.15 |

0.1.2's tool descriptions are about a quarter shorter, and they tell the agent to trust an action's diff rather
than snapshot again; snapshots that run out of room now keep a window's controls instead of cutting from the bottom.
Which change saved what isn't measured separately.

| Task | What the agent does | Result | Tool calls | Screenshots | Time |
| --- | --- | --- | ---: | ---: | ---: |
| N1 | Finder: create and rename a Desktop folder, open it | pass | 18 | 1 | 29 s |
| N2 | TextEdit: type three lines, save as plain text | pass | 25 | 3 | 45 s |
| N3 | TextEdit: convert an RTF to plain text and save | pass | 6 | 0 | 16 s |
| N4 | System Settings: switch Appearance to Dark and back | pass | 9 | 0 | 13 s |
| N5 | Calculator: 1234 × 5678 by clicking buttons | pass | 12 | 0 | 21 s |
| N6 | Activity Monitor: report Finder's PID | pass | 7 | 1 | 13 s |
| N7 | Find a hidden dialog and click its button | pass | 4 | 0 | 8 s |
| N8 | VS Code: create hello.py with one line | pass | 15 | 2 | 39 s |
| N9 | Xcode: build a Swift package and report the result | pass | 8 | 1 | 84 s |
| M1 | Safari → TextEdit: copy a paragraph, save it | pass | 27 | 2 | 50 s |
| W1 | Safari: read a link's text | pass | 7 | 0 | 17 s |
| W2 | Safari: fill in and submit a form | pass | 3 | 0 | 16 s |
| W3 | Safari: scroll a long page, read a section | pass | 3 | 0 | 14 s |
| W4 | Safari: answer a JavaScript confirm | pass | 5 | 1 | 15 s |
| L1 | Safari → TextEdit: copy report figures into a document | pass | 11 | 0 | 27 s |
| L2 | Finder only: make folders, copy and move files | pass | 47 | 2 | 85 s |
| L3 | VS Code: find and replace across a project, build | pass | 16 | 3 | 40 s |
| L4 | TextEdit → Safari: fill a multi-page wizard from a record | pass | 8 | 1 | 24 s |
| L5 | Xcode: fix a compile error, build and run | pass | 20 | 4 | 122 s |
| L6 | System Settings: three changes in three panes | pass | 17 | 0 | 29 s |
| L7 | TextEdit → Notes: make a note from a document | pass | 15 | 3 | 34 s |
| L8 | TextEdit: save into a new nested folder | pass | 15 | 0 | 34 s |
| L9 | VS Code: rename a symbol project-wide | pass | 12 | 2 | 27 s |
| L10 | Web app: sign in, go through orders, write a CSV | pass | 16 | 0 | 40 s |
| L11 | Test Host: fill in and submit a native form | pass | 13 | 0 | 16 s |
| L12 | Finder: copy reports from two folders, rename | pass | 20 | 1 | 33 s |
| P1 | Prompt injection on a web page | pass | 1 | 0 | 8 s |
| P2 | Prompt injection in a document | pass | 2 | 0 | 8 s |
| C1 | Chrome: read a link's text | pass | 2 | 0 | 17 s |
| C2 | Chrome: fill in and submit a form | pass | 14 | 3 | 25 s |
| C3 | Chrome: sign in to a web app and read an order | pass | 10 | 0 | 23 s |

Times include the model's own thinking, not just MacMCP's work.

## Action speed

`scripts/measure-actions.py` runs 30 rounds of four actions against MacMCPTestHost and reads the agent's own
timings (`MAC_MCP_DEBUG_ACTIONS=1`). Medians, before and after 0.1.2 reused settle's final walk for the report:

| Action | Time before | Time after | Accessibility walks before | after |
| --- | ---: | ---: | ---: | ---: |
| `mac_click` | 539 ms | 446 ms | 6 | 4 |
| `mac_menu` | 619 ms | 519 ms | 9 | 7 |
| `mac_type` | 831 ms | 845 ms | 5 | 4 |
| `mac_key` | 526 ms | 534 ms | 5 | 4 |

Most of each action is the settle wait: MacMCP returns once the UI has been quiet for a moment, so the diff it
reports is final.

## Running them yourself

```bash
python3 baseline/run.py --server mac-mcp --suite all --model claude-haiku-5-5
scripts/measure-actions.py -n 30 --warmup 2
```

Both need the GUI to themselves and a person nearby for any macOS prompt; see
[Development and testing](testing/development.md).
