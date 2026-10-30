# Security policy

MacMCP lets an AI agent operate a Mac as the logged-in user, so we treat flaws in its safety layers as security
issues.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub:
[Report a vulnerability](https://github.com/Playback-Software/mac-mcp/security/advisories/new). Don't open a public
issue.

Include the MacMCP version (`mac-mcp --version`), the macOS version, and the steps or tool calls that reproduce it.
We aim to reply within a week and will credit you in the advisory unless you'd rather not be named.

## In scope

- Getting around `policy.json`: driving or opening a denied app, running AppleScript, Shortcuts or page JavaScript
  that isn't allowed, opening a blocked host, or making a looser policy take effect without a person running
  `mac-mcp policy approve`. That includes changing, deleting or adding to the approved-policy records MacMCP keeps in
  the login keychain through the apps an agent drives.
- Answering macOS security or permission prompts, or reading password-field values.
- Typed text or secrets reaching the audit log or agent log unredacted.
- Another local user, or a process outside your account, reaching the agent's socket.
- Screen text being treated as instructions instead of being marked as untrusted.

## Out of scope

- What an agent does with access you granted it. The policy, the GUI lease and the audit log limit and record that
  access, but they don't judge an agent's intent. See [Policy and security](docs/policy-and-security.md).
- Anyone who can already run code as your user, or who has your SSH access. Such code can also change the login
  keychain, including the approved policy.

## Supported versions

Only the latest release gets fixes while MacMCP is before 1.0.
