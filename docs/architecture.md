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

The relay passes MCP messages through unchanged, but it survives an agent restart (a crash, a reinstall,
`mac-mcp restart`). It reconnects for up to 15 s and replays the client's `initialize` handshake, if there was one.
Calls that were in flight when the connection dropped get a JSON-RPC error (`-32603`, "agent restarted"), so the
client retries them instead of hanging. The MCP session itself carries on.

## Protocol layer

The agent speaks both protocol eras on every connection:

- **2026-07-28:** stateless; `server/discover`, then requests that carry their version in `_meta`. Claude Code
  2.1.285+ uses this.
- **2025-11-25 and older:** the `initialize` handshake, which the official Python SDK and older clients use.

The MCP layer is about 450 lines with no dependencies. It replaced swift-sdk 0.12.1 after that SDK's transport
interleaved concurrent responses. Each connection has one reader thread and one serial writer, so messages go out
whole and in order. A `notifications/cancelled` cancels the call it names.

## Web tools

The `web_*` tools drive a **separate automation Safari** through Safari 27's own MCP server (`/usr/bin/safarimcp`).
It has a clean profile, with no logins and with cookies that last only for the agent's session, and it never touches
your Safari windows. A person must turn on Safari ▸ Settings ▸ Developer ▸ "Allow remote automation and external
agents" once. The Developer tab appears after Settings ▸ Advanced ▸ "Show features for web developers". For a site
that needs your logged-in browser, the `mac_*` tools still drive your own Safari through accessibility.

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

## CLI

| Command | What it does |
| --- | --- |
| `mac-mcp` / `mac-mcp relay` | stdio ⇄ agent socket (what MCP clients run); reconnects if the agent restarts |
| `mac-mcp doctor` | Health report; falls back to local checks if the agent is unreachable |
| `mac-mcp install` / `uninstall [--purge]` | Install or remove the LaunchAgent |
| `mac-mcp start` / `stop` / `restart` / `status` | Control the agent (works over SSH) |
| `mac-mcp logs [--audit] [-n N]` | Agent log or audit log |
| `mac-mcp call <tool> ['{json}'] [--save-image PATH] [--timeout S]` | Call one tool from a shell (debugging, scripts) |
| `mac-mcp alerts setup ntfy TOPIC [--server URL]` / `setup url URL` / `test` / `off` / `status` | Where to send alerts when a person is needed (writes `alert_webhook`, sends a test) |
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
