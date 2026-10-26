# Policy and security

## Policy

`~/.config/mac-mcp/policy.json` (written on install; edits apply immediately; `mac-mcp doctor` shows the effective
policy):

```json
{
  "deny_apps": ["com.apple.Terminal", "com.apple.keychainaccess", "com.example.bank"],
  "allow_apps": [],
  "script": { "allowed_apps": ["com.apple.TextEdit", "Finder"], "timeout_seconds": 30 },
  "web": { "enabled": true, "eval_allowed": false, "deny_hosts": ["bank.example"], "allow_hosts": [], "allow_private_hosts": false },
  "shortcuts": { "allowed": ["Resize Images"], "timeout_seconds": 60 },
  "clipboard_read": true,
  "rate_limit_per_second": 10,
  "alert_webhook": "https://ntfy.sh/your-private-topic",
  "alert_cooldown_minutes": 10
}
```

| Key | Effect |
| --- | --- |
| `deny_apps` | Apps (bundle ID or name) agents can't see or drive. They're refused by every tool and hidden from full-display screenshots. When the key is absent it defaults to the apps that would hand an agent a shell, stored secrets or security settings: Terminal, iTerm2, Script Editor, Automator, Shortcuts, Keychain Access, Passwords and System Settings. A list you write replaces the defaults, so keep the ones you still want. |
| `allow_apps` | If non-empty, agents may only see and drive these apps. |
| `script.allowed_apps` | Apps `mac_script` may target. Empty by default, so scripting is off. |
| `script.jxa` | Whether `mac_script` may run JXA. Off by default: JavaScript reaches the shell and the Objective-C bridge through computed names no filter can see, so turning it on gives scripts the agent's full power. |
| `web.enabled` · `web.eval_allowed` | Whether the `web_*` tools run at all, and whether `web_eval` may run JavaScript (off by default). |
| `web.deny_hosts` · `web.allow_hosts` | Hosts (and their subdomains) the web tools may not, or may only, open, read or act on. Only http(s) URLs are ever opened. |
| `web.allow_private_hosts` | Whether the web tools may open this Mac and private-network addresses: `localhost`, `127.x`, `10.x`, `172.16–31.x`, `192.168.x`, link-local (including cloud metadata at `169.254.169.254`), `*.local`. Off by default; a host listed in `allow_hosts` is allowed either way. Names that merely resolve to such an address aren't caught. |
| `shortcuts.allowed` | Shortcuts (name, case-insensitive, or identifier) that `mac_shortcut` may run. Empty by default. A shortcut can do anything its actions can (shell scripts, files, messages), so allow only ones you'd be happy for an agent to run unattended. `mac_shortcut list` shows them all either way. |
| `clipboard_read` | Whether `mac_clipboard` may read the clipboard. |
| `rate_limit_per_second` | Actions are spaced out to at most this rate. |
| `alert_webhook` | POSTs a plain-text alert (ntfy-compatible) when work is blocked on a person: screen locked, a macOS prompt, a missing permission, an invalid policy. |

A policy file that can't be parsed blocks agents (and `mac-mcp doctor` says why) rather than falling back to defaults.

## Security

MacMCP gives whoever can reach it control of the Mac's GUI. The socket is owner-only (`0600`), there is no network
listener, and remote access goes through SSH. Text read from the screen is treated as untrusted data. Password-field
values are never shown, and text typed through `mac_type` is redacted from the audit log. Actions refuse to touch macOS
security and permission prompts, and apps on the policy's deny list.

Secure-field values and their descendants are masked before snapshot labels, search metadata and raw debug output
are built. `web_dialog` prompt input is also redacted from audit arguments; dialog replies and typing mismatch errors
do not copy entered text into audit detail. Cancelling or timing out a call prevents new input, accessibility writes
and app-management requests. A request already sent to an app cannot be recalled and may still complete, so inspect
the current UI before retrying an abandoned action.

`mac_script` runs only against apps a person has allowed in `~/.config/mac-mcp/policy.json`, and refuses shell
escapes (`do shell script`, raw `«event»` codes, AppleScriptObjC) and apps named by a variable rather than a literal.
This is a filter, not a sandbox: it's why JXA, which can't be filtered, stays off unless `script.jxa` turns it on. It also needs macOS's Automation grant for each app. Without the grant it fails at once instead of raising a
consent prompt that nobody answers. A person at the screen approves the first use per app (`request_consent: true`).
`mac_doctor` lists the grant state for each allowed app.
