# Changelog

All notable changes to MacMCP are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
MacMCP is in early development, so tools and policy keys may change before 1.0.

## [Unreleased]

### Added

- `CONTRIBUTING.md` and this changelog.
- A `VERSION` file at the repo root. `scripts/build.sh` reads it, and a unit test fails if the CLI's version differs.
- A GitHub Actions workflow that builds, runs the unit tests and runs `scripts/lint-blocking.sh` on macOS.
- README sections for a first task, updating and uninstalling.

### Changed

- `scripts/build.sh` and `scripts/setup-signing.sh` stop with a fix when full Xcode or Swift 6.1+ is missing, and
  `build.sh` ends with a hint when `~/.local/bin` isn't on `PATH`.
- `swift test` prints a notice when it skips the integration tests, pointing at `scripts/integration.sh`.
- `scripts/soak.py` fails, rather than passing, when MacMCPTestHost isn't installed or never launched, and counts a
  skipped hang phase as a problem unless `--no-chaos` was passed.
- `scripts/protocol-probe.py` has a shebang and is executable.

### Documentation

- The policy reference describes `shortcuts.timeout_seconds` and `alert_cooldown_minutes`.
- The README says `build.sh` picks a login-keychain identity only when there is exactly one; with several it asks for
  `MAC_MCP_SIGNING_IDENTITY`.
- The policy docs say MacMCP 0.1.0 approved nothing; the `approved-policy` item came from development builds.

### Removed

- The stale `baseline/m5.sh` and `baseline/m10.sh` evaluation scripts.

## [0.1.1] - 2026-10-29

Security, reliability and performance fixes from a full review of 0.1.0.

### Security

- **Policy approval.** A change that loosens `policy.json` applies only after a person runs `mac-mcp policy approve` in
  Terminal, which records it as an append-only record in the login keychain. `mac-mcp policy status` shows what's in
  force and what's waiting, `--expect-sha256` approves exactly the bytes a script wrote, and `mac-mcp policy prune`
  removes old records. Tightenings apply at once. Duplicate keys are rejected. An optional root-owned managed policy
  in `/Library/Application Support/MacMCP` suits unattended Macs.
- **More refusals.** Side routes to denied apps and protected files are checked at each input step: Finder selections,
  previews, drags, renames and pastes; Open and Save panels and Go to Folder; `open=`; Services hotkeys in any
  language; key sequences, including those `mac_type` sends; and keys after an app switch. Password managers are
  denied by default.
- **Protected files.** Keychains, common credential stores and files that run code (shell startup files, Git
  configuration, AI clients' settings) are protected, following links, aliases and hard links. Concealed clipboard
  contents are refused, and so is input while a macOS security prompt is up.
- **Gated scripts.** `mac_script` compiles in a sandboxed host and runs in a disposable host behind an Apple-event gate
  that checks every event: Standard Additions are off by default, file parameters are checked against protected paths,
  documents and tabs are checked per event, and page JavaScript needs `web.eval_allowed`.
- **Untrusted text.** Screen and web text is marked with a per-response token that page text can't forge.
- **Audit log.** Typed text, keys, script source and URL secrets are redacted, and write failures are reported.

### Fixed

- Blocking IPC, file locks and subprocesses run on dedicated threads with bounded guard pools that replace stuck
  workers, never on Swift's cooperative pool. Subprocesses have output caps and process-group cleanup.
- Protocol frames, queues and write times are bounded, and session admission is fixed.
- Refs stay honest across snapshots, ids stay unique across restarts, tree walks are iterative and settle is
  deterministic.
- The Safari bridge restarts a `safarimcp` that lost its Safari. Windowless menu commands, and actions that close an
  app's last window, report correctly.

### Changed

- `scripts/build.sh` stages, verifies and swaps the install atomically, with rollback.

### Upgrading from 0.1.0

Run `git pull`, `scripts/build.sh` and `mac-mcp doctor`. On its first start, MacMCP records your current `policy.json`
as the approved policy in your login keychain, and says so once if it's looser than the defaults. After that,
loosening it needs `mac-mcp policy approve`.

## [0.1.0] - 2026-10-26

The first public release: a Model Context Protocol server that lets AI agents see and drive macOS apps through the
accessibility tree.

### Added

- 23 tools: `mac_snapshot` returns compact rows with element refs; actions re-resolve their target, hit-test before
  clicking, verify typed text and answer with a diff; `mac_wait` waits for conditions instead of fixed sleeps.
- A signed `MacMCP.app` LaunchAgent that holds the Accessibility and Screen Recording grants across rebuilds, and the
  `mac-mcp` CLI relay, which also works over SSH. A GUI lease lets only one session drive at a time.
- Menu commands by path, AppleScript in apps the policy allows, Shortcuts, OCR for canvases, and `web_*` tools for a
  separate automation Safari.
- A per-machine `policy.json`, an audit log with typed text redacted, refusals for macOS security prompts and password
  fields, and `mac-mcp doctor`.

[Unreleased]: https://github.com/Playback-Software/mac-mcp/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Playback-Software/mac-mcp/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Playback-Software/mac-mcp/releases/tag/v0.1.0
