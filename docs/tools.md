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
| `mac_app` · `mac_window` | Launch / activate / quit apps (`open=` takes an http(s) or mailto URL or a file, never an app, script or other launcher); list / focus / move / resize / close windows. Neither touches macOS security prompts |
| `mac_wait` | Wait until settled, or until text / an element / a window appears or goes away; use `until=text ocr=true` for text drawn in canvases. `until=unlock` waits up to 10 min for a person to unlock the screen |
| `mac_clipboard` | Get or set clipboard text (reads can be disabled by policy). A password a password manager copied is never read or pasted |
| `mac_script` | AppleScript against literal app targets the policy allows (JXA if `script.jxa` is on); checked again at each outgoing Apple event |
| `mac_shortcut` | List the person's Shortcuts, and run the ones the policy allows (`input=` text in, text out) |
| `mac_doctor` | Permissions, session, health, identity and fixes |
| `web_navigate` · `web_read` | Open a page, or read it as a text tree (`uid=N` on interactive nodes), markdown or a screenshot |
| `web_act` | Click, type, press keys, scroll or pick menu items by uid or visible text; typed values are read back |
| `web_tabs` · `web_dialog` · `web_logs` | Tabs; JavaScript alerts, confirms and prompts; console and network logs |
| `web_eval` | Run JavaScript in the page (off unless the policy allows it) |

Queries search complete sanitized labels and values, even when their displayed rows are shortened. `mac_wait
until=gone` requires an accessibility walk that read every element's text; a loading or truncated tree, or one where
a label, value or child list failed to read, cannot prove a target disappeared (a failed identifier read alone
doesn't hold it up).

`mac_snapshot` defaults to a 1500-token row budget (`max_tokens`). When an overview exceeds it, static text and
headings yield to controls. Within each kind, the focused element and nearby rows, then the top and bottom rows,
get priority; output stays in tree order. Repeated table/list rows with the same role and shape show the first few,
the last, and rows around focus, with `… N more rows like this (use query= or scroll)` for collapsed runs. The final
note counts all unshown rows, including collapsed rows and their controls. Use `query=` or a narrower `scope=` to
find them, or raise `max_tokens`; for offscreen elements, scroll or use `offscreen=true`. Query results retain their
matching order and prefix budget, without repetition folding. Unshown controls keep their refs across snapshots,
and action diffs still compare all rows read from the UI.

For canvas text, for example, use `mac_wait app="My App" until=text query="Ready" ocr=true timeout=30`. OCR waits
need Screen Recording, poll the app's visible window, and return recognized text with screenshot click points.
They support appearance checks only, since recognition errors cannot reliably prove text is absent. The first
recognizer load may exceed a short timeout; the error explains how to retry. Accessibility wait timeouts include
the current window state and a suggested recovery path.

Refs stay meaningful. Before acting on a ref, the action re-reads its element and refuses if the label (or developer
identifier) differs from what the last snapshot, diff or `mac_wait` result showed you (`e10 was "Item 1" but now
reads "Item 7"`), as happens when a virtualised or re-sorted list reuses a row object. Snapshots a tool takes for
itself (an action's before/after, a drag's drop target, `mac_wait`'s polling) never count as having shown you
anything. A control whose label or identifier can't be fully re-read (the read was cut inside it, or a label
source or identifier failed to read) is refused as uncertain rather than assumed unchanged, even if it was shown
unnamed. A list row whose text changed gets a new ref, unless it carries a stable developer identifier, in which
case the text is treated as display state (a clock, a progress figure) and the ref stays. Refs (`e`), snapshot
ids (`s`) and screenshot ids (`c`) never repeat across agent restarts; an id from before a restart is refused with
a message saying so, and a snapshot or screenshot fails outright if its ids can't be recorded on disk. Screenshot
pixels passed to `mac_click` are converted to screen points when the click actually runs (after any action queued
ahead of it, and again after the target app is activated), so a window that moved or resized in between is refused
rather than clicked through. An action's diff lists `- eN` for rows that disappeared only when the walk after the
action read every element and its text; when it stopped early or had read failures, the diff says why instead. A
snapshot whose labels or values couldn't be read says so in a note. See
[Architecture](architecture.md#refs-and-ids) for details.

For how the `web_*` tools work, see [Architecture](architecture.md#web-tools).

## Scripts

`mac_script source='tell application "TextEdit" to get name'` needs TextEdit in `script.allowed_apps` and macOS
Automation consent for MacMCP. Scripts naming no app are refused: name the app literally. The source tokenizer
handles comments, escaped identifiers and `¬` continuations. A sandboxed throwaway compiler returns canonical text
for the parent to check; a second host compiles and executes only that checked text. Compiler-time native effects
cannot write files, create/execute processes, use the network or send app events. `use AppleScript version "2.4"`
and `use scripting additions` are allowed. Other `use` clauses, script-library specifiers, current-application
references (including `of`/`tell` forms), AppleScriptObjC access and raw event/app/process syntax (including `<<…>>`) are refused.
App terms such as Mail's `read status`, `read write` privileges and clipboard-named properties are accepted.

Scripts run in disposable signed MacMCP hosts sharing one hard timeout. Every outgoing Apple event is checked against
app policy and the script allowlist; unknown targets and unapproved commands to the host itself are refused.
Standard Additions default to refused for every target, even an allowed app. `delay`, `current date`, `offset`,
`round`, `random number`, `ASCII character`, `ASCII number` and `time to GMT` are allowed by exact event code.
Refused additions include file I/O, environment access, URL opens, dialogs/choosers, notifications, volume changes, clipboard
commands and script loading. Use `mac_clipboard` for policy-checked clipboard access. The error names the refused
command without its arguments, even if the script catches the error. Runtime errors retain their actual number,
including `-1743` for missing Automation authorization. Result text remains untrusted data.

System Events needs `script.allow_system_events: true` as well as `script.allowed_apps`. Denied or unresolved
process targets, system-prompt and mixed-prompt processes, and all System Events keyboard/mouse input are refused.
Process collections and `whose` process filters are refused early with a clear message; name each process literally.
Finder and System Events open, launch, reveal, select and creation events (including aliases, login items and
property list files) are refused for every file. Every target, including document apps such as TextEdit, gets the
shared ProtectedPaths checks on open/print files, save filenames, move/duplicate destinations, file creation
properties and nested file objects. Writes, deletes and renames also protect containing directories and check new
names; System Events property-list writes are covered. File parameters must resolve locally from event descriptors;
unresolved file parameters are refused, including relative text containing `/` or `:`. Text encodings and absolute
HFS paths are checked too; raw `«data …»` literals are refused. Ordinary body text and Finder window navigation
remain usable. Saves need an explicit filename; a close of one document may use `saving yes saving in` a safe
filename. Other document closes and quits need `saving no`. Apps with protected documents already open are refused:
the parent checks window `AXDocument` and `AXURL` through Accessibility before execution and again before each event.
Unreadable document checks also refuse the event.
Finder, System Events, Terminal, iTerm2 and
Script Editor remain equivalent to a shell; `mac_doctor` warns when they are allowed. JXA's native Objective-C
bridge remains outside the Apple-event gate, so enable `script.jxa` only when you intend to grant that power.
See [Policy and security](policy-and-security.md).

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

## Input targeting and verification

Input stops when a call is cancelled or reaches its deadline. Any keys, mouse buttons and modifiers it pressed are
released before the next action may use the keyboard or mouse. A failed or cancelled drag sends Escape while the
button is held, moves back to its source, then releases there; only a successful drag releases at the destination.
If cleanup is delayed, later actions wait or report that the action lock is busy.

`mac_key` and `mac_type` require the target app to still be running and frontmost. Keyboard ownership follows the
focused element's window, allowing remote accessibility children whose window belongs to the target app. Known Apple
Open/Save panel, WebKit and authorization view services may use the system-wide focused application as their host.
When no focused element can be read, the focused application's pid is used; an unavailable focus read alone does not
refuse keys. Positive evidence that another process holds focus (for example Spotlight or a non-activating panel)
stops input. Dismiss that UI or focus the target app and retry.

All synthesized input refuses while **any macOS security or permission prompt is on screen**, even when another app
still has keyboard focus. A person must answer it. Guards repeat between keys, typing chunks and pointer events, on
GCD workers with an 80 ms AX focus timeout and a 250 ms overall guard budget. A slow guard stops input and cancels a
held drag safely. Each step shares one window-list snapshot between prompt and pointer checks. Multi-clicks keep
their modifiers held through all clicks, releasing them on completion or refusal.

Ref-based mouse clicks choose a point inside the target's visible frame after clipping by scroll areas, web areas,
the window, and lists, tables or outlines inside scroll areas. Structural groups may have visible overflow and do not
clip. At that point, accessibility's hit test must find the target, something inside it, or an ancestor of it in the
same window (WebKit may answer with the view hosting the page). A scroll area, web area, list, table or outline around
the target still counts as covering it: a row scrolled out of one is hit as the viewport itself. Ancestor walks
are cycle-safe and bounded to 512 levels; reaching the bound preserves the clips already found. `mac_scroll` caches
its ancestor clip chain per sequence, refreshes clip frames, and checks before every wheel event that the point
belongs to the target app's window and hits the intended element or a descendant. Helper-process children use their
window's ownership. Move or close an overlapping window before retrying a refused scroll. `to_ref` handles both
vertical and horizontal displacement and refreshes the viewport geometry while scrolling.

Without `ref` or an explicit `mode`, `mac_type` inserts at the current caret, replacing only the current selection.
It verifies the complete result when the original value and UTF-16 selection range are readable. With a ref, the
default remains replacement. `mode=append` explicitly clears the selection and places the caret at the end through
accessibility. If that cannot be done, it refuses: click where to type, then call `mac_type` without mode. It never
sends navigation shortcuts to position the caret.

For readable fields, append verification compares the complete original value plus the typed text; replacement
compares the complete requested text. Leading and trailing whitespace matters. CR and CRLF line endings are treated
as LF. With `submit=true`, a verifiable field must match before Return is pressed; a mismatch or lost readback does
not submit. Secure fields, editors that hide their text, and unreadable values or caret positions are reported as
unverified, including when submitted. Check those fields before retrying so text is not entered twice.
