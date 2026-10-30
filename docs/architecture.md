# Architecture

```text
 local client ──stdio──▶ mac-mcp ─┐
 remote client ─ssh───▶ mac-mcp ─┤  (relay)
                                  ▼
         ~/Library/Application Support/MacMCP/mcp.sock   (0600)
                                  ▼
   MacMCP.app — LaunchAgent, GUI (Aqua) session only, signed, com.playbacksoftware.macmcp
   its own MCP layer (2025-11-25 + 2026-07-28) · owns Accessibility + Screen Recording · audit log
```

Processes started by SSH run in launchd's *Background* session, where screen capture and GUI control don't work and
the login keychain is unavailable. The agent therefore lives in the logged-in GUI session, and everything else
relays to it.

## Relay

The relay passes JSON-RPC messages through unchanged, but it survives an agent restart (a crash, a reinstall,
`mac-mcp restart`). It reconnects for up to 15 s and replays the client's `initialize` handshake, if there was one.
Calls that were in flight when the connection dropped get a JSON-RPC error (`-32603`, "agent restarted"), so the
client retries them instead of hanging. The MCP session itself carries on. One monotonic 15 s deadline covers both connecting and replaying initialize;
an agent that accepts a socket but never answers cannot extend it. Replay must succeed with the original negotiated
protocol revision. A failed or changed handshake fails held requests with `-32603` and ends the relay so the client
can establish a fresh MCP session.

The relay strips client-supplied `#mac-mcp` directive lines. Only its own preamble supplies session, origin and lease
labels, and the agent accepts preamble directives only before the first JSON-RPC message. The relay bounds held
messages to 256 frames / 32 MiB and outstanding requests to 256 / 32 MiB of request ids. Excess requests receive
`-32603`; notifications never receive responses. Relay stdout has no write timeout: SSH and stdio apply
backpressure for as long as the client needs, and a closed client is detected by EPIPE.

## Refs and ids

`RefStore` hands out element refs (`e12`) and keeps them stable across snapshots: the same accessibility object keeps
its ref, else an unambiguous fingerprint (role, identifier, label, tree path) within the same window does. Two things
guard against a ref quietly meaning something else:

- **Reused row objects.** Virtualised and re-sorted lists (Finder, Mail) reuse an `AXRow` for different items, so a
  row or cell whose label changed gets a new ref instead of carrying the old one. The exception is a row or cell with
  a meaningful developer identifier (`AXIdentifier`, not AppKit's generated `_NS:…`) that is unchanged: that names
  the item, so its text (a clock, a progress figure) is display state and the ref stays. The identifier is trusted
  to name the item, not its position.
- **What the agent saw.** For each ref the store remembers the label and identifier as last rendered to the agent:
  by `mac_snapshot` (the rows that fit the token budget), by an action's report (the refs in its diff, or all
  rendered rows when it shows the new state), and by `mac_wait` (the matching rows it returns). Marking takes the
  rendered rows themselves, not the store's entries: a snapshot recorded in between can already hold a newer label
  the agent never saw. Snapshots the agent never sees mark nothing: an action's before/after snapshots, a drag's
  snapshot of its drop target and `mac_wait`'s polling all leave the guard alone, so a control renamed since the
  agent's snapshot is still refused. `SnapshotRequest.markShown` is off by default and only `mac_snapshot` turns
  it on.
  `Actions.resolve` compares the element's current label and identifier with that and refuses on a difference,
  reading them from the snapshot it just took when the ref was re-found, or with one small accessibility walk when
  the element is out of view. An identifier that was shown and is now missing is refused too. An empty current
  label is accepted only when the read was complete and the agent saw the control unnamed as well, or saw it named
  by the text beside it (`associateLabels`), which the control doesn't carry itself; a read cut short or with
  failed reads that loses the label or identifier is refused as uncertain rather than treated as unchanged, even
  when the agent saw the control unnamed, since a lost name reads the same way as no name. Completeness is judged
  per row, not per walk: the walker keeps each attribute's error, and a row is uncertain when one of its label
  sources (title, description, placeholder, help, a value that can be a label, the title element) or its
  identifier failed to read, its children couldn't be enumerated (a row's cells or a button's text name it), a
  descendant failed to read, or the walk was cut inside its subtree. A list whose visible rows couldn't be read
  falls back to its children, which hold the rows too, and is a hole only when it has none. "Unsupported" and "no
  value" are absent, not failed. `kAXErrorFailure`, which some apps (Java, some Qt and Office builds) answer for
  attributes they don't have, is believed only when a second read of those attributes fails too: one batched
  re-read of the identity attributes that answered it, and one re-read of a title element; a read the app couldn't
  complete isn't repeated, since it already cost the messaging timeout. A snapshot of a large app that stopped at
  its node budget therefore doesn't refuse every unnamed control it did read whole, and a non-empty label that came
  back and matches is accepted from an uncertain read. Password fields are never echoed.
- **What absence proves.** `mac_wait until=gone`, an action's list of disappeared rows and the snapshot notes judge
  the walk's *text* completeness (`WalkStats.textComplete`): every node reached, every node read, and every label
  source, shown value (a popup's choice, a field's contents) and child list read whole. A spinner whose title read
  failed while its node read fine is therefore not proven gone. An identifier that failed to read is kept apart:
  it makes a ref uncertain but can't hide text, so it doesn't hold up a wait. A snapshot whose labels or values
  couldn't be read says so in a note.

Ids never repeat across agent restarts. The relay keeps a client's session through a restart, so its `e1` or `c1`
must not resolve to whatever the new agent minted first. `IDBlocks` reserves blocks of numbers (1000 refs, 100
snapshots, 100 screenshots) and records the block's end in `~/Library/Application Support/MacMCP/ids.json` before
any of it is used; each incarnation starts above the file's marks. The write happens once per block, so ids grow
by one block per restart and stay short. A block is issued only once the file is written and synced: if that fails
(disk full, folder unwritable) the snapshot or screenshot fails with a message saying so, since an unrecorded
block would be handed out again after a restart. Every reservation reloads the file under an `flock` on a sibling
lock file, taken off the cooperative pool, so two agent instances sharing the file (a second instance on another
socket) can't take the same block or overwrite each other's marks. A file that exists but can't be read or
decoded is not treated as empty: numbering restarts from the current time in milliseconds, which no earlier
incarnation can have reached, the file is replaced, and the event is logged. That floor is recorded in the file for
every kind, so refs, snapshots and screenshots all restart above it, not only the kind reserved first; the unusable
file stays until its replacement is written and synced, so a replacement that fails (a full disk) leaves an unusable
file for the retry rather than a missing one that would count from 1. The clock is only a last resort: after one
recovery the ids run ahead of it by the blocks issued since, so a second recovery that took its floor from the clock
again would reissue them. The highest number ever reserved, of any kind, is therefore also kept in
`ids.json.highwater`, written and synced before `ids.json` on every reservation that raises it, and a recovery
restarts every kind above that mark; only an install that never had the mark (one from before it was kept) falls
back to the clock, and when both files are unusable no ids are issued until a person fixes or moves them. Each
replacement file is flushed to disk (`F_FULLFSYNC`, or `fsync` where the volume can't) and so is the directory after
the rename, so a power loss can't bring back the old marks. An id below the incarnation's first
block is refused as "from before the agent restarted". Tests inject a temporary path; stores created without one
keep nothing and count from 1.

Screenshot pixels (`mac_click x,y screenshot_id=c3`) stay pixels in the parsed `Target` and are converted to screen
points by `resolve`, under the action lock, so the staleness check (window gone, moved or resized, screenshot too
old) sees the screen as it is when the click runs, not when the call was parsed while another action still held
the lock. The pixels are kept on the `Resolved` target and converted once more after the action activates the app
(`Actions.actionPoint`): an app that moves or resizes its window on activation is refused rather than clicked at
the point worked out while it was in the background.

## Settling

After an action, `Settle` samples a signature of what the agent would see (frontmost app, the target app's windows
and bounds, pop-up menus, its focused element, and a hash of its focused window's rows) until it holds for 250 ms,
or 2 s pass. Two samples of an unchanged UI must hash the same, so the row walk is bounded by a node count, never by
time: a time limit stops at a different node each sample on slow trees (Xcode, VS Code, Chromium) and every action
would report "UI still changing". The walker reports why it stopped (node budget, depth limit, time, cancellation);
only a stop by time is incomparable, since a stop at the node budget or the 60-level depth limit lands on the same
node next time. An app that can't deliver the budget within 0.4 s gets a smaller budget, three quarters of what it
did deliver, remembered per process, so later samples hash the same prefix of its tree. The floor of 100 nodes
applies only to apps that delivered at least that many; a slower app gets a budget it can meet, down to one node,
rather than one every sample misses (which left every action waiting out the timeout). A cancelled walk changes
nothing. Other apps' windows are left out (a notification banner or menu-bar item redrawing would otherwise reset
the quiet timer), and a cancelled call stops sampling at once.

## Protocol layer

The agent speaks both protocol eras on every connection:

- **2026-07-28:** stateless; `server/discover`, then requests that carry their version in `_meta`. Claude Code
  2.1.285+ uses this.
- **2025-11-25 and older:** the `initialize` handshake, which the official Python SDK and older clients use.

The MCP layer has no dependencies. It replaced swift-sdk 0.12.1 after that SDK's transport
interleaved concurrent responses. Each connection has one reader thread and one serial writer, so messages go out
whole and in order. A `notifications/cancelled` cancels the call it names. Modern calls capture their own client
info, protocol revision and lease token before dispatch; omitted client info means `unknown`. Legacy calls retain
identity negotiated by initialize. The connection log label is captured once for stateless clients; later requests
keep their own identity without changing that label. Every JSON-RPC object must include `"jsonrpc":"2.0"`; a missing
or different value is rejected with `-32600`, including on notifications.

Revision 2025-03-26 accepts [JSON-RPC batches](https://modelcontextprotocol.io/specification/2025-03-26/basic#batching) of up to 128 entries. Responses form one array in input order (execution may
finish in any order); notifications and cancelled calls contribute no response. An all-notification batch has no
response, and an empty batch returns one `-32600` error object. Other revisions reject batches with `-32600`.

Frames are limited to 16 MiB. Each connection buffers at most 64 input frames / 32 MiB, admits at most 32 concurrent
tool calls / 32 MiB of request data, and bounds queued output and all pending batch collectors to 32 MiB each.
The dedicated reader waits for frame and byte capacity instead of dropping pipelined messages; teardown wakes a
reader waiting for capacity. Oversized input frames and output queue overflow close the connection. Excess tool
calls receive `-32603`. A response larger than one frame instead returns `-32603` for its id with its size and advice
to narrow the request. Each batch collector also fits one 16 MiB frame, including array framing, and reserves space
for an error for every entry before accepting larger results. Entries exceeding the remaining space get the same
response-too-large error. A batch whose error ids alone cannot fit the frame or shared response budget is rejected
before dispatch with one `-32603` error. Transport writes time out only after 10 s without accepting bytes; every
successful partial write resets that timer. Time queued behind earlier writes does not consume it. One write may
also take at most ten minutes plus a second per 16 KiB in all, so a reader that accepts a byte just inside each 10 s
cannot hold the writer, and the frames queued behind it, indefinitely.
Teardown atomically rejects future sends, cancels calls and shuts down I/O, then asynchronously joins the reader and
writer before the socket owner closes its descriptor. Late task completions cannot write to a reused descriptor.

`AgentClient` uses one monotonic deadline for each initialize, call or tool-list exchange, including all send and
receive work (and connect for initialize). It handles partial writes, EINTR and EAGAIN, suppresses SIGPIPE, bounds
received frames to 16 MiB, and rejects non-finite, non-positive or excessively large timeouts.

## Web tools

The `web_*` tools drive a **separate automation Safari** through Safari 27's own MCP server (`/usr/bin/safarimcp`).
It has a clean profile, with no logins and with cookies that last only for the agent's session, and it never touches
your Safari windows. A person must turn on Safari ▸ Settings ▸ Developer ▸ "Allow remote automation and external
agents" once. The Developer tab appears after Settings ▸ Advanced ▸ "Show features for web developers". For a site
that needs your logged-in browser, the `mac_*` tools still drive your own Safari through accessibility.

safarimcp's `navigate_to_url` and `page_interactions` reply in the format of the last `get_page_content` call, so a
`web_read as=markdown` is one bridge transaction: the markdown read and the call that puts the text tree back run
under the same turn of the bridge's lock, and a `web_navigate` or `web_act` queued behind it can't run in between
and come back without uids. The restore runs even if the read is cancelled, on a task the cancellation doesn't
reach. The lock's turn ends as soon as it abandons a cancelled or overdue request, so each request also holds the
bridge until its own code has finished, restore included, and the next one waits for that. If the restore itself
fails, the session's format is marked unknown and the next `web_navigate` or `web_act` sets the text tree first,
failing with a message rather than running in the wrong format if that doesn't work either; a new safarimcp session
starts in the text-tree format, so the mark doesn't outlive the session. Each markdown read marks the format with its
own number, and its restore clears only that mark, never a later read's.

**Abandoned requests.** A request already sent to safarimcp can't be taken back: when the deadline or a cancellation
abandons a `web_act`, its `page_interactions` keeps clicking and typing in Safari. The bridge therefore keeps every
request it has sent in an `inFlight` table until safarimcp answers (or the session ends), and marks it abandoned when
its caller gives up. The next request that touches the page (everything except `list_tabs`, `browser_dialogs` and the
console and network logs; answering a dialog is how a blocked interaction gets to finish) waits for those replies, up to
20 s, counted against its own deadline. If they haven't come by then the bridge restarts the safarimcp session, which
ends whatever was still running, and that request fails with "An earlier page_interactions was abandoned but still
running in Safari after 20 s, so the session was restarted (open tabs are gone). Retry."; the call after it starts on a
new session. A request that waited and then saw the reply runs normally, without an error. An interaction parked behind a
dialog that doesn't finish after the dialog is answered counts as abandoned too.

The bridge does not send MCP `notifications/cancelled`. safarimcp is a thin shim over Safari's WebDriver framework, with
no cancellation handling visible in the binary; whether it honors the notification could not be tested without driving
the real Safari. The MCP spec says a receiver that honors a cancel sends no reply, which the hold could not tell apart
from a wedged request, so a cancel that worked would still cost the 20 s wait and a restart. The bounded hold and the
restart are the guarantee.

The watchdog watches the main queue, task pool and action lock. Each lock holder publishes its monotonic deadline;
only a hold beyond that deadline plus a 15 s margin counts as a lock stall. A Shortcut with a 300 s timeout therefore
gets its full 305 s lock budget without triggering the former 180 s watchdog threshold.

Nothing on the task pool waits for another process. The policy is evaluated on a dedicated thread (`PolicyStore`),
which is the one that waits on the keychain; tool calls await it through a continuation, or take the last status
after a short patience, and non-gating reads (timeouts, the alert webhook) take the last status at once. Subprocesses
go through `Subprocess.run`. `scripts/lint-blocking.sh` rejects blocking calls in agent code, including timed
semaphore and condition waits, unless the line says why it runs off the pool.
Dedicated-thread timers use monotonic deadlines and Darwin's relative condition wait, so a wall-clock adjustment
cannot extend their waits. A wait rechecks its deadline at least every 100 ms.

## Health checks

Every 10 minutes the agent checks itself (`HealthMonitor`). Problems are logged, sent to the policy's
`alert_webhook` (set it up with `mac-mcp alerts setup …`, at most one alert of each kind per cooldown), and shown in
`mac_doctor`. The checks pause while the screen is locked or nobody is logged in, which is normal on an unattended
box. They catch:

- **Lost Accessibility or Screen Recording permission.**
- **Screen capture that sees only the wallpaper** although windows are on screen (a stale Screen Recording grant).
- **Secure Input held by one app for 15+ minutes** (a focused password field, or a terminal's Secure Keyboard
  Entry). It makes typing into other apps fail.
- **A macOS prompt waiting for a person**, with its text read through accessibility. The monthly Screen Recording
  re-approval gets its own message. Agents never answer these prompts.
- **Stuck guard workers.** Input guards run on bounded native threads (`Input.guardWork`): four for focus and drag
  cleanup checks, and a separate four for route checks, which resolve paths and can block in the kernel on an
  unresponsive SMB/NFS mount. When every worker of a pool has been busy for 10× the pool's timeout, the pool adds a
  replacement thread (up to 12 for focus, 16 for route; surplus threads retire once the stuck calls return), and the
  stuck count and age are reported here, also while the screen is locked. Checks still fail closed meanwhile.

## Subprocesses

`Subprocess` runs every child (`osascript`, the script host, `shortcuts`, `launchctl`) on one kqueue thread, so no
worker waits for a child. A child leads its own process group, and timeouts and cancellation signal the whole group
(SIGTERM, then SIGKILL after 2 s), so helpers it started die with it. stdout and stderr are each capped at 16 MiB; past
that the child is stopped, `Output.truncated` is set, stderr ends with a note, and a child that still exited 0 is
reported as exit 1. A call cancelled before it spawns never spawns.

## CLI

| Command | What it does |
| --- | --- |
| `mac-mcp` / `mac-mcp relay` | stdio ⇄ agent socket (what MCP clients run); reconnects if the agent restarts |
| `mac-mcp doctor` | Health report; falls back to local checks if the agent is unreachable |
| `mac-mcp install` / `uninstall [--purge]` | Install or remove the LaunchAgent (`--purge` also removes the app, its support folder and the approved-policy records in the login keychain) |
| `mac-mcp start` / `stop` / `restart` / `status` | Control the agent (works over SSH) |
| `mac-mcp logs [--audit] [-n N]` | Agent log or audit log |
| `mac-mcp call <tool> ['{json}'] [--save-image PATH] [--timeout S]` | Call one tool from a shell (debugging, scripts) |
| `mac-mcp alerts setup ntfy TOPIC [--server URL]` / `setup url URL` / `test` / `off` / `status` | Where to send alerts when a person is needed (writes and approves `alert_webhook`, sends a test) |
| `mac-mcp policy approve` / `status` / `prune` | Apply changes to `policy.json` that loosen it (it lists them first and records the approval in the login keychain), show which policy is in force, when it was approved and what's waiting, or delete older approval records that other builds made (macOS asks for the keychain password for each). See [Approving changes](policy-and-security.md#approving-changes) |
| `mac-mcp lease acquire` / `release` / `status` | Take the GUI for yourself (evals, GUI tests): other clients may look but not act, and agent reinstalls wait |
| `mac-mcp remote-setup [--name mac]` | Checks Remote Login, the agent and the policy, then prints the `claude mcp add … -- ssh …` line for another machine. Never touches `~/.ssh` |
| `mac-mcp version` | The CLI version |
| `mac-mcp report [--since 7d] [--top N]` | Real use from the audit log: sessions and where they came from, route share (GUI input vs direct routes vs looking), errors and refusals grouped by kind, slowest calls. Evals and tests are counted separately |

### Sharing the GUI

Several sessions can be connected at once: local Claude Code, remote ones over SSH, the CLI. Looking is always
allowed. Acting is limited to one session at a time:
- **Claiming.** A session's first acting call claims the resource: `gui` for input, apps and windows, or `web` for
  the automation Safari behind `web_*`. The two are separate, so a web session doesn't hold up a GUI session.
- **Holding.** The claim lasts until the session has gone 60 s without acting, or disconnects. A dropped SSH link
  frees it at once.
- **Waiting.** Another session's acting call waits up to 30 s, then fails with who holds the claim, since when and
  when they last acted.
- **The lease.** It still wins: a session holding the lease doesn't claim, and other sessions can't act while it's
  held.

Lease ownership is derived from the currently active token at each admission. Claim waiters recheck leases on
each attempt, and admitted calls recheck both lease and claim state before execution and after taking the action
lock. Releasing or expiring a lease removes its claim bypass. A shared cross-process admission guard covers only
the admission check and each recheck; lease acquisition holds its exclusive counterpart while publishing the lease
file. Neither claim/action-lock waits nor the tool body hold that guard, so even a long-running Shortcut cannot
prevent lease acquisition. The CLI retries contention (an admission check or an existing lease) for at most 60 s,
at 250 ms intervals; file I/O errors fail immediately.

A lease published while a call waits for the action lock is observed by the final recheck and prevents execution.
Synthesized input also checks the lease on a GCD worker before each input step and again after a route check.
Each action carries the requesting session's token. A stat of the lease file (device, inode, nanosecond mtime and
size) avoids rereading unchanged contents; an atomic replacement invalidates the cache. Expiry and holder-process
liveness are evaluated on every check. A new active lease owned by another token revokes the input session, stopping
long typing, repeated keys, scrolling and drags at the next guard. Only paired key/button/modifier cleanup may still
run. A malformed or unreadable lease file stops input too.

This is cooperative handoff at input-step boundaries, not an atomic transfer of all GUI activity: publication can
race the last check and the event that immediately follows it, and a lease does not drain already-issued app IPC,
AppleScript or Shortcut work. Neither running actions nor input checks hold the cross-process admission lock.

`mac_doctor` lists the current claims.

When the screen is locked, acting calls get SCREEN LOCKED. A person is alerted (with which agent is waiting), and
the agent can `mac_wait until=unlock` for up to 10 minutes while they unlock it via Remote Access. Nothing ever tries
to unlock it.

### Usage report

Each audit entry records its session id, where the session came from, and the GUI lease holder if it presented one.
- **Session id:** chosen by the relay, so it stays the same across agent restarts.
- **Origin:** `local`, or `ssh:<address>` when a client on another machine ran `ssh <host> mac-mcp`. The relay
  decides this from its parent processes, not from `SSH_CONNECTION` alone: a client started on this Mac from an
  SSH terminal inherits that variable but is local.
- **Lease holder:** eval runs and the integration tests hold a lease.

`mac-mcp report` uses these to split real use from evals (leased), test clients, the CLI and entries written before
sessions were recorded. It then summarises only the real sessions.

## Signing

macOS ties the Accessibility and Screen Recording grants to the app's signing certificate, so MacMCP must be signed
with a real identity that stays the same across builds. Ad-hoc signing changes on every build, and the grants would be
lost each time.

Set it up once:

```bash
scripts/setup-signing.sh                  # create a self-signed "MacMCP Local Development" certificate
scripts/setup-signing.sh --import ID.p12  # or import an Apple Development / Developer ID identity you exported
```

Either way the identity goes into a **dedicated keychain**, which `build.sh` unlocks itself. That keeps builds working
unattended over SSH, where the login keychain is locked. A self-signed certificate is enough: it has no team, but the
designated requirement pins the certificate itself, so grants survive rebuilds.

`build.sh` picks the identity in this order:

1. `MAC_MCP_SIGNING_IDENTITY`, a certificate SHA-1.
2. The one identity in the dedicated keychain.
3. The one valid code-signing identity in your login keychain, such as the free **Apple Development** certificate
   Xcode creates (Xcode ▸ Settings ▸ Accounts). This works from a local Terminal, but not over SSH.

If it finds none, or more than one, it stops and says so.

| Variable | Default |
| --- | --- |
| `MAC_MCP_SIGNING_IDENTITY` | Unset: picked as above |
| `MAC_MCP_SIGNING_KEYCHAIN` | `~/Library/Keychains/mac-mcp-signing.keychain-db` |
| `MAC_MCP_SIGNING_KEYCHAIN_PASS` | `~/.config/mac-mcp/signing-keychain.pass` (mode 0600) |

Changing the signing identity or bundle ID means granting both permissions once more. If prompts don't reappear,
`tccutil reset Accessibility com.playbacksoftware.macmcp` (and `ScreenCapture`) followed by `mac-mcp restart`
brings them back.

### Installing

`build.sh` never touches the working install until its replacement is ready. Only one install runs at a time: it
takes a lock directory (`~/Applications/.MacMCP-install.lock`, holding its PID; a lock whose process is gone is
removed), and before anything else it finishes or undoes an install that was cut short (step 0). The transaction
lives in `scripts/install-swap.zsh`; `scripts/test-install-swap.sh` runs it against temp directories (it also runs in
`swift test`).

0. If an earlier install stopped between its first change and its commit (Ctrl-C, a crash, power loss), it left a
   journal (`.MacMCP-install.state`). The previous app and CLI are put back, and a build that had started an agent
   gets it restarted. A rollback that could only put one of them back leaves the journal in a `rollback` phase, so
   this step finishes it before anything else: the journal is cleared only once both files are back, and until
   then no backup is treated as disposable, since the live CLI may be the new build that looks sound on its own.
   With no journal, a `.previous` next to a live copy is removed only if the live copy passes its checks
   (signature, executable), and a missing live copy is restored from it. If neither passes, both are left alone
   and the install stops.
1. It builds, then assembles and signs the app and the CLI in a staging directory next to the install, and checks
   them (`codesign --verify --strict`, `Info.plist`, an arm64 executable, the bundle ID, and that the CLI runs).
   Any failure, signing included, stops there with the installed MacMCP unchanged.
2. It checks the GUI lease again (it was first checked before the build, which can take minutes).
3. It writes the journal, then swaps the new files in by rename. The old app stays as
   `~/Applications/MacMCP.app.previous` and the old CLI as `~/.local/bin/mac-mcp.previous` (a copy, renamed into
   place so a half-written backup is never trusted).
4. It restarts the agent and waits for it to answer tool calls. If it doesn't, the previous app and CLI are put
   back and restarted. Otherwise the journal and the `.previous` copies are deleted. (`--no-start` installs the
   files only, so there is no health check and the old copies are deleted at once.) An interrupt (Ctrl-C, `kill`)
   during steps 3 or 4 puts the previous files back before the script exits. A rollback that fails part way, from
   a failed swap step, a failed health check or an interrupt, keeps its journal and backups for step 0 of the
   next run, and doesn't restart an agent on mixed files.
