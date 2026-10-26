# Tools

```text
mac_doctor ─▶ mac_snapshot ─▶ mac_click / mac_type / mac_key / mac_menu (by ref) ─▶ diff in the response
                   ▲                                                      │
                   └──────────── mac_wait (until settled / element) ◀─────┘
```

| Tool | What it does |
| --- | --- |
| `mac_snapshot` | See an app's UI as element refs, with blockers in the header |
| `mac_screenshot` | Pixels of a window, a display (`display=list` to choose one) or a zoomed region (id maps pixels back to the screen); `ocr=true` returns the text on screen with click points instead, for canvases and custom-drawn UI |
| `mac_click` · `mac_type` · `mac_key` | Act by ref (or screenshot pixel); typing is read back and verified |
| `mac_menu` | Run menu-bar commands by path (`"Format > Make Plain Text"`) through accessibility |
| `mac_scroll` · `mac_drag` · `mac_hover` | Scroll by lines or pixels (with modifiers, e.g. cmd-wheel zoom) or until a ref is visible; drag between refs, points or onto a Dock icon; hover to reveal tooltips |
| `mac_app` · `mac_window` | Launch / activate / quit apps; list / focus / move / resize / close windows |
| `mac_wait` | Wait until settled, or until text / an element / a window appears or goes away; use `until=text ocr=true` for text drawn in canvases. `until=unlock` waits up to 10 min for a person to unlock the screen |
| `mac_clipboard` | Get or set clipboard text (reads can be disabled by policy) |
| `mac_script` | AppleScript against apps the policy allows (JXA if `script.jxa` is on); refuses shell escapes |
| `mac_shortcut` | List the person's Shortcuts, and run the ones the policy allows (`input=` text in, text out) |
| `mac_doctor` | Permissions, session, health, identity and fixes |
| `web_navigate` · `web_read` | Open a page, or read it as a text tree (`uid=N` on interactive nodes), markdown or a screenshot |
| `web_act` | Click, type, press keys, scroll or pick menu items by uid or visible text; typed values are read back |
| `web_tabs` · `web_dialog` · `web_logs` | Tabs; JavaScript alerts, confirms and prompts; console and network logs |
| `web_eval` | Run JavaScript in the page (off unless the policy allows it) |

Queries search complete sanitized labels and values, even when their displayed rows are shortened. `mac_wait
until=gone` requires a complete accessibility walk; a loading or truncated tree cannot prove a target disappeared.
For canvas text, for example, use `mac_wait app="My App" until=text query="Ready" ocr=true timeout=30`. OCR waits
need Screen Recording, poll the app's visible window, and return recognized text with screenshot click points.
They support appearance checks only, since recognition errors cannot reliably prove text is absent. The first
recognizer load may exceed a short timeout; the error explains how to retry. Accessibility wait timeouts include
the current window state and a suggested recovery path.

For how the `web_*` tools work, see [Architecture](architecture.md#web-tools).

## Example snapshot

```text
app: MacMCPTestHost (com.playbacksoftware.macmcp.testhost) · window "MacMCP Test Host" · focus: e1 · snapshot s11
blockers: none
--- 31 rows (28 with refs) · 77 nodes in 30 ms
heading "Order Form"
e1 textfield "Name" = "" [focused]
e2 password "Password"
heading "Toppings"
e3 checkbox "Bacon" [unchecked]
e5 popup "Size" = "Small"
e6 button "Submit"
text "Nothing submitted yet."
e10 row "Item 1"
… 44 offscreen elements skipped: scroll to reveal
```
