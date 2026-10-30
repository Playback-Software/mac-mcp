# Contributing

MacMCP lets an AI agent operate a Mac, so changes are reviewed with that in mind: read
[Policy and security](docs/policy-and-security.md) before touching the safety layers.

## Build

You need macOS 26 or later on Apple silicon and full Xcode 26 or later (Swift 6.1+). The Command Line Tools alone can't
build TestHost's SwiftUI macros. Select Xcode with `xcode-select -s` or `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`;
the scripts select it themselves.

```bash
swift build                # compile everything
scripts/setup-signing.sh   # once: a signing certificate (see docs/architecture.md#signing)
scripts/build.sh           # build, sign and install ~/Applications/MacMCP.app and ~/.local/bin/mac-mcp
```

Don't run `build.sh` while an eval or integration run holds the GUI lease; it refuses to.

## Tests

Unit tests need no permissions and don't touch the GUI:

```bash
swift test --skip IntegrationTests
```

Some tests time things and can fail when the machine is busy. Rerun a failure alone (`swift test --filter NameOfTest`)
before treating it as real.

Integration tests drive the installed agent and the TestHost fixture app, so they need a logged-in, unlocked GUI
session and the Accessibility and Screen Recording grants for MacMCP:

```bash
scripts/build.sh && scripts/build-testhost.sh
scripts/integration.sh [swift test args, e.g. --filter ActionTests]
```

`integration.sh` takes the GUI lease for the run, so nothing else drives the GUI meanwhile. Leave the Mac alone while
it runs. A plain `swift test` skips the integration tests and says so. `scripts/soak.py` and the agent task suite in
`baseline/` also need the lease; see [Development and testing](docs/testing/development.md).

Add a test with each fix or feature, in the same style as its neighbours (Swift Testing: `@Suite`, `@Test`,
`#expect`). Put anything that needs the GUI under `Tests/IntegrationTests`.

## Lint

```bash
scripts/lint-blocking.sh
```

It fails on calls that can wedge the agent's small thread pool (`waitUntilExit`, `sleep`, `flock`, `DispatchQueue.sync`,
timed waits and others). `build.sh` runs it too. Use `Subprocess`, `Task.sleep` or a dedicated thread instead; a line that
really must block can say why with `lint:allow-blocking <reason>`.

CI runs `swift build`, `swift test --skip IntegrationTests` and the lint on each pull request and each push to `main`
(`.github/workflows/ci.yml`, on GitHub-hosted macOS). The OCR unit test skips itself there when `CI` is set.

## Code and docs

- Match the code around you: naming, idiom and comment density. Comments are sparse, plain and say why, not what.
- The agent has no third-party dependencies; keep it that way.
- The version lives in `VERSION`. `cliVersion` in `Sources/mac-mcp/main.swift` must equal it (a unit test checks), and
  `build.sh` reads `VERSION`.
- Docs use plain, concise sentences and no marketing tone. Change the docs with the behaviour: `docs/tools.md` for
  tools, `docs/policy-and-security.md` for policy keys and refusals.
- Add a line to the Unreleased section of [CHANGELOG.md](CHANGELOG.md) for anything a user would notice.
- Keep commits focused, with a message saying what changed and why.

## Vulnerabilities

Don't open a public issue or pull request for a security problem. Report it privately as described in
[SECURITY.md](SECURITY.md).
