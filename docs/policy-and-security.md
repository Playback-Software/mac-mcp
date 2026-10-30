# Policy and security

## Policy

`~/.config/mac-mcp/policy.json` (written on install; `mac-mcp doctor` shows the policy in force). Edits that tighten it
apply at once; edits that loosen it wait until you approve them with `mac-mcp policy approve` (see
[Approving changes](#approving-changes)):

```json
{
  "deny_apps": ["com.apple.Terminal", "com.apple.keychainaccess", "com.example.bank"],
  "allow_apps": [],
  "script": { "allowed_apps": ["com.apple.TextEdit"], "allow_system_events": false, "timeout_seconds": 30 },
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
| `deny_apps` | Apps (bundle ID or name) agents can't see or drive. They're refused by every tool and hidden from full-display screenshots. An entry matches the app's bundle ID and every name its bundle gives it, so `"Terminal"` also denies `com.apple.Terminal`, and the reverse. When the key is absent it defaults to the apps that would hand an agent a shell, stored secrets or security settings: Terminal, iTerm2, Ghostty, Warp, Alacritty, kitty, WezTerm, Hyper, Script Editor, Script Debugger (every version), the Script menu, Automator, Shortcuts, Spotlight, Raycast, Alfred, Keyboard Maestro (editor and engine), Hammerspoon, Keychain Access, Passwords, the common password managers (1Password, Bitwarden, Dashlane, KeePassXC, LastPass, Proton Pass, Enpass) and System Settings, including the older and helper bundle IDs these apps use. A list you write replaces the defaults, so keep the ones you still want; `mac-mcp install` writes them into a new policy.json, so a file written by an older version lacks the newer ones. |
| `allow_apps` | If non-empty, agents may only see and drive these apps. |
| `script.allowed_apps` | Apps `mac_script` may target. Empty by default, so scripting is off. |
| `script.allow_system_events` | Default false. System Events needs this explicit opt-in **and** an entry in `script.allowed_apps`. It is equivalent to a shell. Process targets must pass app policy; unresolved processes, keyboard/mouse input, opening files/apps and creation events are refused. |
| `script.timeout_seconds` | Hard deadline for the disposable script host (default 30 seconds; tool maximum 120). Timeout or cancellation terminates the host. |
| `script.jxa` | Whether `mac_script` may run JXA. Off by default: JavaScript reaches the shell and the Objective-C bridge through computed names no filter can see, so turning it on gives scripts the agent's full power. |
| `web.enabled` · `web.eval_allowed` | Whether the `web_*` tools run at all, and whether `web_eval` or Safari/Chrome page JavaScript through `mac_script` may run JavaScript (off by default). |
| `web.deny_hosts` · `web.allow_hosts` | Hosts (and their subdomains) the web tools may not, or may only, open, read or act on. Only http(s) URLs are ever opened. |
| `web.allow_private_hosts` | Whether the web tools may open this Mac and private-network addresses: `localhost`, `127.x`, `10.x`, `172.16–31.x`, `192.168.x`, link-local (including cloud metadata at `169.254.169.254`), `*.local`. Off by default; a host listed in `allow_hosts` is allowed either way. Names that merely resolve to such an address aren't caught. |
| `shortcuts.allowed` | Shortcuts (name, case-insensitive, or identifier) that `mac_shortcut` may run. Empty by default. A shortcut can do anything its actions can (shell scripts, files, messages), so allow only ones you'd be happy for an agent to run unattended. `mac_shortcut list` shows them all either way. |
| `clipboard_read` | Whether `mac_clipboard` may read the clipboard. With it off, pasting (⌘V, Edit ▸ Paste) is refused too unless the clipboard holds text MacMCP put there, since pasting into a document and reading it back would read the clipboard. Whatever the setting, a clipboard that a password manager marked as secret (`org.nspasteboard.ConcealedType` or `TransientType`, as 1Password and Apple Passwords do), or that came from a denied app (`org.nspasteboard.source`), is never read or pasted. |
| `rate_limit_per_second` | Actions are spaced out to at most this rate. |
| `alert_webhook` | POSTs a plain-text alert (ntfy-compatible) when work is blocked on a person: screen locked, a macOS prompt, a missing permission, an invalid policy, policy changes waiting for approval. |

Policy files must be UTF-8 JSON objects with the expected setting types. Duplicate keys at any depth (including
escaped spellings of the same key), malformed JSON and invalid types block agents; `mac-mcp doctor` says why. The
approved record stays unchanged.
Settings that don't gate anything, such as the alert webhook and timeouts, come from the approved policy meanwhile.

### Approving changes

policy.json is an ordinary file, and the apps agents drive (TextEdit, Finder) can edit or delete it. So MacMCP keeps
the policy you last approved in your login keychain, in items named "MacMCP approved policy" (service
`com.playbacksoftware.macmcp.policy-approval`), and compares each new version of policy.json with it, key by key.
Agents can't reach the keychain: Keychain Access and Passwords are on the default deny list, agents have no shell, and
`~/Library/Keychains` is a protected location. Each approval, first baseline and recorded tightening is a record in an
item of its own, and the newest record is the approved policy (see [Keychain records](#keychain-records)).

- **Nothing looser:** the new file applies at once and becomes the approved policy. If the keychain doesn't take it
  (locked, say), MacMCP still enforces it, says so, and writes it again each time it reads the policy. Meanwhile the
  older record still in the keychain doesn't replace it: only a record that is no looser, or a later
  `mac-mcp policy approve`, does. So putting policy.json back the way it was counts as a loosening. "Later" doesn't
  depend on the clock alone: each record carries a sequence number, one more than the highest in the keychain when it
  was made. At equal sequences a person's record wins, then the latest millisecond, then deterministic record
  contents; the random account name never decides which policy applies.
- **Anything looser:** MacMCP keeps enforcing the approved policy. It writes the change to `agent.log`, sends an
  alert, and refusals and `mac_doctor` say that a person must run `mac-mcp policy approve`. Run it in Terminal: it
  checks the file, lists what loosens, and records it in the keychain as the approved policy (if the keychain is
  locked, macOS asks you to unlock it). It then deletes the older records it replaces, except those another build of
  MacMCP made, and says how many stay. `mac-mcp policy status` shows what's in force, when it was approved and what's
  waiting. A script that writes policy.json and then approves it should pass `--expect-sha256 <hex>`, the SHA-256 of
  the bytes it wrote (`shasum -a 256`): the approval is then refused, and nothing recorded, unless the file still has
  exactly those bytes, so an edit made in between isn't approved with it.
- **policy.json missing:** the approved policy stays in force; `mac-mcp policy approve` puts the file back from it.
  Deleting the file never reverts to the built-in defaults.
- **policy.json invalid:** agents are blocked until it's fixed, as above.
- **Nothing approved yet** (the first run after installing): the current file, or the built-in defaults if there is
  none, is approved as it is. If it's looser than the defaults, MacMCP says so once (log, alert, `mac_doctor`). Until
  that first approval is recorded in the keychain, agents are blocked (`POLICY BLOCKED`): MacMCP tries again each
  time it reads the policy, or a person can run `mac-mcp policy approve` in Terminal. Otherwise a later edit to the
  file could become the baseline when the agent restarts.
- **The approved policy can't be read** (the records are missing, the newest one is damaged or from a newer MacMCP,
  or the keychain is locked): a running agent keeps enforcing the approved policy it read before, and says a person
  must run `mac-mcp policy approve` (log, alert, `mac_doctor`). An agent that starts without one blocks agents
  (`POLICY BLOCKED`) until then. MacMCP never makes whatever policy.json says the new baseline once a policy has been
  approved, and it never puts a record back itself: your approval does.

`~/Library/Application Support/MacMCP/policy.approved.json` is a readable copy of the approved policy, for you to
look at. MacMCP rewrites it from the keychain and never reads it back; only its presence counts, as a sign that a
policy was approved on this Mac before, so the keychain records going missing blocks agents rather than looking like
a first run. `mac-mcp uninstall --purge` removes both.

#### Keychain records

MacMCP has no Team ID, so each keychain item belongs to the one build that created it: its partition list names that
binary's code hash, which every rebuild or upgrade changes. macOS asks for your login keychain password before any
other build reads the item's password field, changes the item or deletes it, even when MacMCP's call says no prompt
may be shown. It asks nothing to read an item's attributes or to add a new item. So:

- Each record is kept in an item's attributes, not its password field, and is never changed once written. Every
  approval, first baseline and recorded tightening adds a new item, with an account like `approval.12.3f9a1c2e`
  (`approval.<sequence>.<random>`).
- MacMCP reads every record's attributes and takes the newest: the highest sequence (each record's is one more than
  the highest it found), then a person's record over the agent's, then the latest millisecond, then record contents
  (format, author as UTF-8 bytes, policy bytes). A record it can't read (damaged, or from a newer MacMCP) is placed by
  the sequence in its account. Only legacy and unrecognized accounts fall back to when the keychain last changed
  them. Equal modification times are ambiguous: the damaged record might be newest, so approval is blocked. A
  damaged record clearly before the newest readable one is ignored, and `mac_doctor` and `mac-mcp policy status`
  mention it. If it may be newer, the approved policy isn't known, as above.
- Both the agent and CLI take a process-shared lock (`policy-approval.lock` in the support directory) before reading
  the ledger, comparing and appending. The agent compares against the record read inside that transaction, including
  restrictions a person approved meanwhile. Lock acquisition never waits. A busy agent (a person's `mac-mcp policy
  approve` waiting at a keychain prompt, say) keeps comparing policy.json with the approved policy it read before, as
  when the keychain can't be read: a change that tightens it applies at once, in memory, and is recorded once the lock
  is free; a change that loosens it waits. An agent with no approved policy yet blocks. The holder writes its pid,
  start time and whether it's the agent into the lock file, so the CLI says who holds it and since when: for the agent,
  run `mac-mcp restart` if it doesn't finish; for another `mac-mcp` command, finish or quit it. A keychain add that
  times out keeps the lock until the underlying call finishes, and the next transaction reads the ledger again,
  including any late append. The lock file stays in place while processes may use it. An unrecorded tightening that
  conflicts with restrictions another agent recorded blocks tools until a person approves; it never overwrites those
  restrictions. Without a readable ledger, the agent only enforces tightenings in memory.
- The agent only ever adds records (the first baseline and tightenings). It never changes or deletes one, so it never
  causes a keychain prompt. Policy evaluations run on a thread of their own, never on the threads tool calls share,
  and its keychain calls give up after a few seconds, so even a keychain that holds a call up can't stall tool calls:
  calls that come meanwhile wait for the evaluation briefly without holding a thread, then use the status found
  before. A keychain call that hasn't returned after its few seconds shows in `mac_doctor`, with how long it has been
  running; after about a minute it's logged and alerted, since an add then holds the approval lock (`mac-mcp restart`
  clears it).
- `mac-mcp policy approve` deletes the records it replaces that macOS lets it delete without asking: those this build
  of the CLI made. It checks each item's partition and access lists first, which asks nothing. The rest stay, ignored,
  and it says how many. `mac-mcp policy prune` deletes them: it says how many records other builds made, and macOS
  then asks for your login keychain password once for each (enter it, or click Deny to keep that record). In normal
  use few stay: the agent's own (the first baseline, and tightenings) and those from before an upgrade.
- The single item that MacMCP 0.1.0 kept (account `approved-policy`) is read like any other record, at sequence 0
  if it has none. New records come after it, and `mac-mcp policy prune` deletes it.

Each item's access list trusts MacMCP's own agent and CLI (matched by their code signature, so rebuilds signed with
the same certificate qualify). Like the rest of the login keychain, the items don't stop software already running as
you from changing them, which is outside what MacMCP defends against.

Looser means any of these:

- an entry removed from `deny_apps`, `web.deny_hosts` no longer covering a host it did
- `allow_apps` or `web.allow_hosts` widened, including emptied (which allows everything), or `web.allow_hosts`
  gaining a private-network address while `allow_private_hosts` is off
- entries added to `script.allowed_apps` or `shortcuts.allowed`
- `script.allow_system_events`, `script.jxa`, `web.enabled`, `web.eval_allowed`, `web.allow_private_hosts` or `clipboard_read` turned on
- `rate_limit_per_second`, `alert_cooldown_minutes` or any timeout raised
- `alert_webhook` removed, added or changed
- for keys this version doesn't know: a boolean turning on, a number named like a timeout, limit or maximum going up,
  an `allow…` list growing or emptied, a `deny…` or `block…` list shrinking

Comparison uses the same decoded settings and matching keys as enforcement. App entries and shortcut names are
case-insensitive and treat NFC and NFD Unicode forms alike; lookalike characters are distinct. GUI app lists trim
leading and trailing whitespace, as before. Script-target entries and shortcut names preserve it, so removing spaces
from an approved entry requires approval when it grants a new target or shortcut. Host entries use the same
host-and-subdomain matching in comparison and enforcement, including URL entries, whitespace and trailing dots. Known settings never depend on a second parser's
choice of value.

`mac-mcp alerts setup` and `alerts off` approve their own change to `alert_webhook`, but nothing else that's waiting
(and nothing at all while the approved policy can't be read).

### Managed policy

For a Mac that runs agents unattended, install a policy that only root can change. If
`/Library/Application Support/MacMCP/policy.json` exists and is exclusively controlled by root, MacMCP uses it alone
and ignores `~/.config/mac-mcp/policy.json`:

```bash
sudo mkdir -p "/Library/Application Support/MacMCP"
sudo cp ~/.config/mac-mcp/policy.json "/Library/Application Support/MacMCP/policy.json"
sudo chown -R root:wheel "/Library/Application Support/MacMCP"
sudo chmod 755 "/Library/Application Support/MacMCP"
sudo chmod 644 "/Library/Application Support/MacMCP/policy.json"
```

Edit it with `sudo`; changes apply at once, with no approval step. The file and every directory from its folder
through `/` must be root-owned and not group- or other-writable. ACL entries granting writes, additions, deletion,
attribute changes, ownership changes or ACL changes are refused, even if the grant names root (root already has
owner access). Read-only grants and deny entries are allowed. Symlinks in this chain are refused. MacMCP walks the
chain with directory descriptors, opens the file with `O_NOFOLLOW`, checks it with `fstat` and reads from that same
descriptor. A failed trust check ignores the managed policy and produces a warning in `mac_doctor`. A trusted but
invalid managed JSON file blocks agents. To go back to the user policy, `sudo rm` it.

### Evaluation harness

The baseline runner and its Notes scripting fallback temporarily approve only their own changes. They first run
`mac-mcp policy status` and refuse pending or blocked policy states and managed policies. A shared lock file excludes
other harness processes while policy changes are in progress; Notes checks can nest inside the runner's override.
Both the original user file (including its absence) and the keychain record in force are backed up under
`baseline/state/policy-backup-*`, and every `policy approve` exit status is checked. Each approval passes
`--expect-sha256` with the hash of the bytes the harness just wrote, so an edit to policy.json made in between (by
the agent under evaluation, say) is refused rather than approved, and the harness then reads policy.json and the
newest keychain record back and stops if either differs. Cleanup approves the saved approved policy again (a new
record), then restores the original user file or removes it if it was absent. Restoration runs before the runner
releases its GUI lease. If restoration fails, the harness reports the backup location and keeps both records there
for recovery. The harness only reads keychain items; it never changes one.

## Security

MacMCP gives whoever can reach it control of the Mac's GUI. The socket is owner-only (`0600`), there is no network
listener, and remote access goes through SSH. Password-field values are never shown. Actions refuse to touch macOS
security and permission prompts, and apps on the policy's deny list.

### Untrusted text

Text read from the screen, a web page, a script, a shortcut or the clipboard is data, never instructions. Tools
mark it with one random token per response, picked by the server when the call starts. Lists and bodies sit between
two lines that carry the token:

```text
<<untrusted k3j9x2>>
…window titles, page text, script output…
<<end k3j9x2>>
```

A value inside a sentence uses the same marks on one line, cut to a sensible length and with its newlines turned into
spaces:

```text
clicked e6 button <<untrusted k3j9x2>>Save<<end k3j9x2>> (accessibility press)
```

Only a mark with the response's token counts. The text can't know the token, and any `<<` inside it is broken up
(`a << b` becomes `a < < b`), so a page that prints its own boundary lines ends nothing. The rule is the same
everywhere: a string a tool did not write itself is never outside a mark, whether it is in a list, a summary or an
error. That covers:

- snapshots (the header, blockers and rows are one block; the tool's own notes follow it) and action reports
  (labels in the summary, tooltips and help text inline; the new state and the diff in the block);
- screenshot OCR (the recognised lines are a block, the window title in the summary is inline) and `mac_wait`
  results, timeouts and window matches;
- `mac_window` and `mac_app` lists and replies (window titles), shortcut names and lists, `web_*` page text, tab
  lists, logs and dialogs, `mac_script` and `mac_shortcut` output and errors, clipboard reads;
- errors that quote a label, a dialog or menu title, a Dock item, a Safari reply or stderr.

App names and bundle IDs, which policy matches on, are the exception in short confirmations; they are marked
wherever they come from a list.

### Audit log

`~/Library/Logs/MacMCP/audit.jsonl` records what was done, not what was typed or read. The server redacts before it
writes:

| What | Logged as |
| --- | --- |
| `mac_type` and `mac_clipboard` text, `web_dialog` prompt text, `web_act` typed values, arguments named `password`, `token`… | `[REDACTED n chars]` |
| `mac_key` keys | Shortcuts (`cmd+s`) and named keys (`return`, `tab`, arrows, `f5`) as they are. Printable keys with no modifier, or only shift, are dropped: `[8 printable keys redacted]` |
| `mac_script` source, `web_eval` code | Length and a short SHA-256 prefix: `[script: 482 chars, sha256:3fa9c1d2]` |
| `mac_shortcut` input | `[REDACTED n chars]` |
| URLs (`web_navigate`, `web_tabs`, `mac_app open=`, any other argument, and any URL in a detail) | Of any scheme (`HTTPS://`, `myapp://`, `mailto:`) and any case, without credentials, query and fragment: `https://shop.example/cart?…#…`. A file path in `open=` is kept as it is |
| `mac_script`, `mac_shortcut` and `web_eval` outcomes | Exit status, an error category, how long the output was and nothing of its text: `applescript → Notes: exit 1, script error, 8 chars of stderr`. A script can print whatever it read, and no filter can tell a secret from the rest |
| Details of the other tools | The role and ref of what was acted on (`e6 button → clicked e6 button (accessibility press)`, `hovered e6 button at 40,12`), and the tool's own words in errors. Anything marked as screen text (labels, tooltips, window titles, dialog titles) is replaced by `…`. Then known secret values are removed and the line is cut at 120 characters (200 for successes) |

`outcome` is `ok`, `error`, or `refused` for calls the policy and safety layers turned down. If the log can't be
written, the agent log (`~/Library/Logs/MacMCP/agent.log`) says so: the first failure at once, then at most one a
minute with a count of how many were missed.

Secure-field values and their descendants are masked before snapshot labels, search metadata and raw debug output
are built. Dialog replies and typing mismatch errors do not copy entered text into audit detail. Cancelling or timing out a call prevents new input, accessibility writes
and app-management requests. A request already sent to an app cannot be recalled and may still complete, so inspect
the current UI before retrying an abandoned action.

MacMCP never touches its own files or what runs at login. `mac_app open=`, typing into a file panel (Open, Save, Go
to Folder) or Finder, and clicks and drops on items that stand for files all refuse these protected locations:
`~/.config/mac-mcp`, `~/Library/Application Support/MacMCP`, `~/Library/Logs/MacMCP`, `~/Library/LaunchAgents`,
`~/.ssh`, the installed CLI (`~/.local/bin/mac-mcp`), app (`~/Applications/MacMCP.app`) and test host
(`~/Applications/MacMCPTestHost.app`), their rollback and staging entries, the keychains (`~/Library/Keychains`,
which hold the approved policy and the signing identity), the shell startup files
(`~/.zshenv`, `~/.zshrc`, `~/.zprofile`, `~/.zlogin`, `~/.zlogout`, `~/.bash_profile`, `~/.bashrc`, `~/.bash_login`,
`~/.profile`), other files that run code the next time Git or a shell starts (`~/.gitconfig`, `~/.config/git/config`,
`~/.config/fish`, `~/.config/zsh`) and `/Library/Application Support/MacMCP`.
Other tools' credentials: [`~/.config/gh`](https://cli.github.com/manual/gh_help_environment),
[`~/.aws`](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html),
[`~/.netrc`](https://curl.se/libcurl/c/CURLOPT_NETRC_FILE.html),
[`~/.git-credentials`](https://git-scm.com/docs/git-credential-store),
[`~/.docker/config.json`](https://docs.docker.com/reference/cli/docker/),
[`~/.kube`](https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/),
[`~/.gnupg`](https://gnupg.org/documentation/manuals/gnupg/GPG-Configuration-Options.html),
[`~/.npmrc`](https://docs.npmjs.com/files/npmrc/),
[`~/.pypirc`](https://packaging.python.org/en/latest/specifications/pypirc/),
[`~/.config/gcloud`](https://docs.cloud.google.com/sdk/docs/configurations),
[`~/.azure`](https://learn.microsoft.com/en-us/cli/azure/azure-cli-configuration),
[`~/.password-store`](https://www.passwordstore.org/),
[`~/.config/op`](https://developer.1password.com/docs/cli/config-directories/) (1Password CLI),
[`~/.config/hub`](https://hub.github.com/hub.1.html) and
[`~/.terraform.d/credentials.tfrc.json`](https://developer.hashicorp.com/terraform/tutorials/cloud/cloud-migrate),
and, with the same rules:

- 1Password CLI's older `~/.op`;
- Git's `~/.config/git/credentials`;
- package and build tools: `~/.cargo/credentials.toml`, `~/.cargo/credentials`, `~/.gem/credentials`, `~/.m2/settings.xml`,
  `~/.m2/settings-security.xml`, `~/.gradle/gradle.properties`;
- secrets and databases: `~/.vault-token`, `~/.pgpass`, `~/.my.cnf`;
- cloud storage: `~/.s3cfg`, `~/.boto`, `~/.config/rclone`, `~/.oci`, `~/.config/configstore` (the stored logins of
  Node-based CLIs);
- AI assistants: `~/.gemini`, `~/.config/github-copilot`, and the AI clients' settings below;
- DigitalOcean, Cloudflare and Vercel, where macOS puts them: `~/Library/Application Support/doctl`,
  `~/Library/Preferences/.wrangler`, `~/Library/Application Support/com.vercel.cli` (and `~/.config/doctl`,
  `~/.wrangler`, which newer and older versions use);
- files that run code the next time something starts, like the shell startup files: `~/.gitconfig` and
  `~/.config/git/config` (Git runs pagers, hooks and `!` aliases from them), `~/.config/fish`, `~/.config/zsh`, and AI
  clients' settings, where an MCP server, a hook or a configured command runs whatever it names: `~/.claude`,
  `~/.claude.json`, `~/.codex`, `~/.cursor` and `~/Library/Application Support/Claude`. An agent that could edit its
  own client's MCP servers would be outside this policy;
- the Services cache `pbs` keeps, `~/Library/Caches/com.apple.nsservicescache.plist`: MacMCP refuses the key
  equivalents it lists (see Services below), and a rewritten one could drop them.

The list is data in `ProtectedPaths` (`credentialFolders`, `credentialFiles`, `codeRunningFolders`,
`codeRunningFiles`, all relative to the home folder): to protect another tool, add its path there.
Paths are compared after expanding `~`, resolving `..`,
symlinks and Finder aliases, and ignoring case. Hard links to existing protected files are checked by device and
inode too. Their containing directories can be opened, but cannot be renamed, moved, deleted or replaced; unrelated
entries inside `~/.config`, `~/.docker`, `~/.terraform.d`, `~/.cargo`, `~/.m2`, `~/.gradle`, `~/.local/bin` and
`~/Applications` (and any other folder that holds only some protected files) stay usable.

The routes that open things are checked against the app policy as well:

- `mac_app open=` takes only http(s) and mailto URLs and file paths. Other schemes (`x-apple.systempreferences:`,
  `shortcuts:`, an app's own scheme) are refused. A host on `web.deny_hosts` is refused (`allow_hosts` and the
  private-address rule apply to the `web_*` tools only). Files that run, install or
  point somewhere when opened (`.app`, `.command`, `.terminal`, `.tool`, `.workflow`, `.action`, `.pkg`, `.mpkg`,
  `.scpt`, `.scptd`, `.applescript`, shell scripts, `.jar`, `.shortcut`, `.prefPane`, `.mobileconfig`, `.webloc`,
  `.inetloc`, `.fileloc`), and executables, are refused, and so is a file whose handler is a denied app (opening
  through Finder means the file's default app).
- A click or drop on a Dock tile, or a drop on an app icon, counts as opening that app, and a click on a link with an
  app's scheme counts as opening its handler. A double-click on a Finder item, and opening Finder's selection (⌘O,
  ⌘↓, File ▸ Open, Open With), get the same file checks. Finder won't move, copy, cut, paste, duplicate, alias,
  rename, delete, open, preview (Quick Look) or show the info of a selection that includes a protected item, and
  won't copy, cut, duplicate, alias or delete a folder that contains one (the home folder, `~/Library`, `~/.config`):
  its copy would hold the protected files. With a protected item selected, only a short list of command keys is allowed (⌘N, ⌘W,
  ⌘T, ⌘[, ⌘], ⌘↑, ⌘F, ⌘,, ⌘H, ⌘1, ⌘2 and the Go menu's shortcuts); every other command chord is refused, including ⌘3 (column view),
  ⌘4 (gallery view) and ⇧⌘P (Preview pane), which show the selected file, and ⌥⌘O, which opens it like ⌘O. Navigation,
  view and window keys work as usual with an unreadable selection, except those that show the selected file (⌘3, ⌘4,
  ⇧⌘P, ⌘Y, Space): they show what is selected in the window's files wherever focus is, so they are checked against
  the selection of every file list of the window (focus in the sidebar doesn't hide it), which must be readable and
  free of protected items. The View menu's items are held to the same rules, known by their key equivalents: as
  Columns, as Gallery and Show Preview as those keys, as Icons and as List as ⌘1 and ⌘2, and any other item (one
  without a key equivalent too) is refused while a protected item is selected.
- Finder's selection is read from accessibility each time, from the window holding focus (the main window while
  focus is in Finder's rename field or a dialog). Nothing selected in a list that was read is an empty selection.
  A failed read is told apart from an attribute an element doesn't have: a list whose selected rows or children fail
  to read has an unknown selection, even when the other reads empty, and an element whose role or children fail to
  read could hide a file list, so the window's selection is unknown too.
  When it can't be read (no file list in the window, a list whose selection can't be read, or a selected item with
  no file URL), every key and menu item that acts on it is refused with "Finder's selection couldn't
  be checked; select the items again or use a path you can see": ⌘C, ⌘X, ⌘V, ⌥⌘V, ⌘D, ⌘L, ⌘⌫, Return, Enter, Delete,
  ⌘I, ⌥⌘I, ⌘Y, ⌘R, ⌘O, ⌘↓, Space and every ⌃⌘ chord. The same goes for the items of the Finder, File and Edit
  menus, the toolbar's Action menu and contextual menus, however they are chosen (`mac_menu`, a click, Return or
  Space on the highlighted item), except those whose key equivalent is one that leaves the selection alone (New
  Folder, New Finder Window); an item without a key equivalent (Rename, Compress, Make Alias) counts as acting on it,
  and so do the buttons of a window that lists files (its toolbar, the sidebar) and drags of Finder items. Buttons of
  a window that lists none (the Copy window's Replace, a confirmation) answer what was already checked. Keys and items
  that never touch the selection (⌘N, ⌘W, ⌘F, ⌘A, ⌘Z, ⌘1 and ⌘2, ⌘[ and ⌘], ⌘↑, ⌘T, Go
  shortcuts such as ⇧⌘C, ⇧⌘D and ⇧⌘G, the Go, Window and Help menus) work as
  usual, and so does everything when the selection is readable and safe. With nothing selected, Get Info and the
  inspector show the window's folder, which is checked instead. While focus is in a text field (a name being edited,
  the search field), keys edit its text.
- Finder sets no AXDocument on its windows, so a window's folder is the parent of the first items it lists (each
  column's in column view, where an empty column's folder is the one selected before it), or the path bar's last
  folder. An empty icon, list or gallery view names none.
- Finder renames an item in a field of its own and takes the row's name field away meanwhile. The item renamed is the
  selected one under that field: its file when it can be read (icon view). Otherwise (list and column view) it is the
  item the agent's last checked key, menu command or click in Finder was on: every route that starts a rename (Return,
  File ▸ Rename, a click on a selected item's name) is checked and notes the one item it acts on, with its identity.
  That item counts while it is still where it was noted, in the folder listed, and the only item selected there; so
  `~/notes.txt` can be renamed in list view though the home folder holds protected items. Failing that, the folder it
  is listed in must hold nothing protected at any depth. The new name is checked against that folder too.
- ⌘V and ⌥⌘V in Finder's file list (not a field) copy or move the clipboard's files into the window's folder, and
  anything else on the clipboard becomes a new clipping file there. They are checked as a copy: the files may not be
  or hold protected items, and no name may land on a protected location in the folder the paste lands in: the window's,
  or in column view the focused column's and the folder selected in it (every column's when the focused column can't
  be told), so a paste into `~/.docker/scratch` isn't refused because `~/.docker` is shown as a column. The files are
  the ones Finder copied at MacMCP's request (⌘C or Copy, checked against the selection; Finder's copy bumps the
  clipboard's change count once, and nothing else may have copied since), followed by their identity (a file
  reference) and checked under the name they have at the paste as well as the one they were copied with, since Finder
  pastes a file renamed or moved since under its new name (one that is gone is refused); or, when macOS lets MacMCP read the
  clipboard without asking, the files on it; other files, such as ones a person copied, are refused, since reading
  them could raise macOS's paste prompt. In an empty window whose folder isn't shown the paste is refused; column view
  (⌘3) or the path bar names it. A drag of Finder items carries the window's selection when the item grabbed is part
  of it, else that item, and is checked the same way into the folder under the drop (a folder's row or icon, else the
  folders the window shows; a sidebar place or an empty window is refused). It is read before the button goes down:
  while a drag is under way Finder answers hit tests on its lists with the scroll area around them. So a drag from
  Finder or a file panel with ⇧ or ⌘ held is refused: on the button going down they change the selection it carries. A double-click
  opens the item under it wherever it lands on the item's row, and one on an item that can't be read is refused.
- File panels and Finder won't name a file as `.app`, `.command`, `.terminal`, `.tool`, `.workflow`, `.action`,
  `.pkg`, `.shortcut`, `.prefPane`, `.mobileconfig` or a location file, which act when opened even as plain text.
  (Scripts and source files such as `.sh` and `.py` can be saved; opening them is refused.) A path typed into a file
  panel's field is checked with its current value and selection, again before keys or buttons commit it. Only text
  set with `mac_clipboard action=set` may be pasted there. Go to Folder commits the path in its field or the
  completion row selected under it, which carries its path as an identifier rather than a file URL: both are checked,
  so a safe path goes through and a completion of a protected folder (`~/.ss` for `~/.ssh`) is refused, as is a field
  or a selected completion whose path can't be read. A commit is also refused when part of the panel can't be read:
  an element's role or children, or a list's selection, since a failed read may hide a selected file or a name field.
- A sheet, popover, dialog or floating panel counts as a file panel only on evidence, so ordinary dialogs (the Fonts
  and Find panels, a rename or login sheet) take names and pasted text like any window. The evidence is a bounded
  read of the container (300 elements, six rows of each list, kept while the panel stays open): an element owned by
  the out-of-process Open/Save service (`com.apple.appkit.xpc.openAndSavePanelService`), a column view, a list or
  outline whose rows carry file URLs, AppKit's identifiers for the panel's name field, sidebar, Go to Folder field and
  buttons, or `open-panel` / `save-panel` on the window or sheet. A sheet or dialog that can't be read completely
  fails closed and is treated as a file panel; so is a popover inside a document window, which may be the one that
  renames the document's file. Finder is always treated as one. A line that is a path (`/…`, `~…`, `file:…`) is
  checked against the protected locations in every field, typed or pasted from text MacMCP set, and a concealed
  clipboard is refused wherever it is pasted.
- Services and Finder's Quick Actions are refused in `mac_menu`, clicks on their menu items and Return/Enter/space
  activation of highlighted menu items: shortcuts run only through `mac_shortcut` and its allowlist. They are known by their titles in every language macOS ships (read from
  AppKit's and Finder's own localizations), and a menu ending in AppKit's "Services Settings…" counts as Services
  whatever it is called. `mac_key` also refuses their key equivalents: user overrides from the `pbs` domain's
  `NSServicesStatus`, providers' declared defaults unless an override disables or replaces them (including
  Terminal's ⇧⌘M and ⇧⌘A, which macOS enables by default), and readable Shortcuts global hotkey records in preferences
  or the local Shortcuts database. Which declared services macOS enables by default isn't recorded anywhere readable
  (AppKit decides from a built-in list), so every declared default counts. A key is allowed when the frontmost app's
  own menus (not its application menu, which holds Services) give it an enabled command: AppKit runs the app's command
  first, so Finder's ⇧⌘A goes to Applications. Discovery reads the bundles in each Services and Applications folder
  and its subfolders, not deeper, within a time limit, and adds the Services macOS has registered, from the cache
  `pbs` keeps (`~/Library/Caches/com.apple.nsservicescache.plist`, read only, and only when it is the person's own
  plain file: it lists providers wherever they sit, inside other bundles too). The cache only adds keys: it sits in the
  person's Caches folder, so it never stands for a scan cut short, and it is protected so that GUI routes can't rewrite
  it. A scan cut short may have missed a Service, so the key equivalents of macOS's own Services are refused and so is every
  chord with both ⌘ and ⇧ (⇧⌘, ⌥⇧⌘, ⌃⇧⌘) that the frontmost app's menus don't claim; ordinary keys, and chords
  without ⇧, stay available. The result is cached for two seconds. Shortcuts storage that macOS doesn't
  expose remains unreadable; menu activation is guarded independently. While Spotlight is denied (the default), its
  hotkey is refused.
- In one `mac_key` call, no keys may follow one that brings another app forward (⌘Tab, ⌘`, ⌘Q, ⌘H, Spaces and
  Mission Control keys): they'd reach an app nobody checked. Each input step checks live selection, field and clipboard
  state under the action lock, including keyboard activation of menu commands. Paste and Open use command metadata
  across localized menus. Open With requires a resolved app; Other… is refused.
  No AX read can show that an earlier key of the same call was handled (keys go 50 ms apart), so a key's check
  could read state from before it. While the target is Finder (its Open With chooser included), a file panel or an
  open menu, a key that acts on the selection (Return, Enter, Tab, Space, Delete, Forward Delete, any command chord,
  type-select after navigation) must be the first key of its call, including across repeats; the call is refused
  before its first key when the target is already there. Everywhere, a commit (Return, Enter, Space, Save/Open,
  paste, Finder's ⌘↓) can't follow a key that may open a panel or menu (Return, Space, a command chord other than
  editing ones, a function key): its check couldn't see what opened. Elsewhere, Tab, Space and Return sequences
  (`tab, return` in a dialog, Space paging, `cmd+a, delete`) are ordinary input.
  `mac_type` follows the same rules: a newline in its text is a Return key and a tab a Tab key, and they count with the
  text before them (and the ⌘A of `mode=replace`) as the keys of one call. In Finder, a file panel, the Open With chooser
  or an open menu, text that holds a newline or tab is refused before anything is typed unless the control key comes
  first (`submit=true` presses Return after the text instead). Elsewhere, a second newline is refused like
  `return, return` unless the focus is a multi-line text area, where it only breaks the line, so multi-line text still
  goes into editors; plain text without a newline or tab is checked as text only. A file panel is a sheet or dialog
  with a save-name field, a column browser, a file URL, or parts served by the panel service; one that can't be read
  through counts as one. Residual: Space that presses a button opening a panel, followed by Space, isn't refused.
- Input focus reads use a short timeout. If the focused element can't be read and another process has a visible
  window above the target's front window, keyboard input is refused, even when the focused application reads as the
  target: a nonactivating panel leaves the target frontmost while holding the keyboard. Status items in the menu
  bar (above the normal level, in a display's top strip, no taller than its menu bar) and the Dock's own level don't
  count. Route checks have a separate two-second budget for AX walks and file/handler lookups; per-step focus
  and prompt guards retain their 250 ms budget, on GCD workers with the response's untrusted-text token preserved.
- Drag drop checks use the current window owner at both endpoints. Protected replacement checks apply to Finder
  and Open/Save panel browsers, including remote panel services. On abort, Escape is sent only with no system
  prompt and verified keyboard focus in the source app. Returning to the source also needs fresh ownership and drop
  route checks, so a custom drag view that ignores Escape still cannot receive an unchecked source drop.
  If those checks fail or time out, cleanup releases over the menu bar's left end, before the Apple menu, on a
  display where the window list shows the window server's menu bar frontmost at that point (no status item, panel or
  overlay there), where nothing takes a drop. With no such point (a full-screen app hides the menu bar), it releases
  outside the union of active displays: the least harmful choice left, since the window server may clamp that point
  to a display's edge, where a window could take the drop. It never deliberately releases over a prompt, denied
  window, Desktop or Trash. A custom tracking implementation can still interpret cleanup differently, so MacMCP
  reports and logs where it released and asks for a new snapshot. Leaving the button held would let a person's next mouse movement finish
  the drag unpredictably. The input lock stays held until cleanup completes.
- Route refusals mark file names and paths as untrusted, using the response's one token. Their audit detail records
  the route category only, without the name, path or other screen text.

`mac_window` and `mac_app` refuse to move, close, hide, activate or quit a macOS security or permission prompt.
Prompts are recognized by bundle ID or system executable (SecurityAgent, the TCC, Automation and accessibility consent
prompts, Gatekeeper's CoreServicesUIAgent, Touch ID, passkeys, Bluetooth pairing, AirDrop, screen sharing and remote
management requests), with the old process names as a fallback. Processes that also show other windows (sharingd and
AirDropUI, the screen-sharing agents, loginwindow, Software Update) count as a prompt only for their windows that look
like one, so a screen-sharing session's overlay doesn't block agents; none of their windows may be acted on. A window of
theirs is a prompt if it sits above the normal window level (the floating, modal-panel, alert and pop-up levels)
without covering a whole display, or if accessibility calls it a dialog, system dialog, floating window or sheet, marks
it modal, or finds a default or cancel button in it. It isn't one if it is an ordinary window on the normal level (a
standard window with a close button) or covers a whole display without being a dialog (the lock screen, which the
session check handles, or a screen-sharing curtain). Anything else, including a window accessibility can't describe,
counts as a prompt. The input guard gives accessibility 50 ms a message and 100 ms a process for this, and remembers
each window's answer for 1.5 seconds (by window, layer and frame), so a process that answers slowly costs one step
some time once rather than stopping every step; a window it couldn't describe in time counts as a prompt.

These are filters on the routes MacMCP knows of, not a sandbox. The approval step is what keeps a loosened
policy.json from taking effect, and it doesn't rest on these filters: the approved policy is in the login keychain,
which none of the apps agents may drive can change. For a Mac nobody watches, a [managed policy](#managed-policy)
also keeps the policy out of reach of the user account itself.

`mac_script` requires at least one literal app target, for example `tell application "TextEdit"`. App names and
bundle IDs are checked after comments and line continuations are removed by one tokenizer. AppleScript first
compiles in a throwaway host with a permanent Seatbelt sandbox. The host initializes the system OSA component,
then installs the sandbox before the first `OSACompile` call; a sandbox failure stops the request. The sandbox
denies by default: it permits filesystem metadata, reads of system and app resources, executable library mapping
and read-only sysctl queries. File writes, process creation/execution,
network access, service lookups and Apple-event sends are denied. This confines native effects from compiler-time
framework loading or initializers even if the source tokenizer disagrees with AppleScript.
During both compilation passes, the send callback permits only the verified safe Standard Additions addressed to
the host itself, so property initializers such as `property today : current date` work. All other events receive
`errAEEventNotPermitted` instead of terminating the host. This lets AppleScript fall back from a running app's
terminology request (`ascr/gdte`) to its bundle dictionary without contacting the app or checking Automation consent. Finder's
`name of every file of desktop` compiles with readable terminology in the sandboxed host.

The compiler returns only `OSAGetSource` canonical text. The parent repeats the construct and session-safety checks,
then starts a second host which compiles and executes **only that checked text**, with another canonical recheck.
No compiler bytecode, property values or native objects cross into the execution host. Both children share one hard
timeout and cancellation stops whichever child is running. Dynamic AppleScript app/process targets and JXA
`Application(...)` calls with non-literal arguments are refused. Source checks refuse URL opens, dialogs/alerts,
environment access, file metadata, mounting
volumes, script libraries (including `tell script "Library"`), shell commands, raw data literals (`«data …»`),
raw event/app/process codes (including `<<…>>`), AppleScriptObjC imports and all current-application references, including possessives, `of current
application`, `tell current application` and aliases assigned from it. `use AppleScript version "2.4"` and
`use scripting additions` are allowed; every other `use` is refused. App terms such as Mail's `read status`,
`read write` privileges and properties containing `clipboard` are allowed. Actual Standard Additions file I/O and
clipboard commands are refused by event code, even with `clipboard_read: true`. No pasteboard inspection is needed,
and refusals never return clipboard contents.

Script hosts use OpenScripting inside disposable children of MacMCP's **own signed executable**,
resolved once at startup through dyld and started in a hidden script-host mode before agent services start. The
parent kills it at the hard timeout or on cancellation. An OSA send callback checks each outgoing Apple event's
real target against both app policy and `script.allowed_apps`, including targets represented by bundle ID, PID,
process serial number or application URL. Unresolved and remote targets are refused. Standard Additions event
classes default to refused for every target, including allowed apps. Exact-code allowances cover `delay`, `current
date`, `offset`, `round`, `random number`, `ASCII character`, `ASCII number` and `time to GMT`; the last uses the
case-sensitive event code `syso/GMT `, including the trailing space. Additions in shared classes are refused by
exact event code, such as `fndr/gstl` (`system attribute`), without blocking Finder's
whole class. Events to the host itself also default to refused. During execution, a refused event terminates the
host immediately, so a script cannot catch it. The parent discards any earlier script output and returns only the command refusal,
without event arguments. This gate covers Apple events, not native code executed by JXA's Objective-C bridge:
`script.jxa` remains an explicit grant of that broader power and is off by default.

Finder, System Events, Terminal, iTerm2, Script Editor and Safari are equivalent to a shell. `mac_doctor` warns when any is
listed in `script.allowed_apps`; allow them only if you trust that access. Prefer individual document apps such as
TextEdit. System Events also needs `script.allow_system_events: true`; denied or unresolved process specifiers and
all keyboard and mouse commands, including hidden key-down/key-up commands and coordinate clicks, are blocked at
the event gate. Every system-prompt or mixed-prompt process is refused using the same process-level bundle ID,
executable and name classifications as the GUI guards; scripting cannot target even a non-prompt window of a mixed
process. Process collections (`every process`, `application processes`, `whose` filters) are unsupported and refused
by the source check with a request to name each process literally. Finder and System Events `open`, `launch`,
`reveal`, `select` and creation events (including `make new alias`, login items and property list files) are refused **for all files**,
including indirect object specifiers. This conservative rule covers app bundles, executable scripts, launchers and
documents whose default handler is denied without resolving app objects or racing a default-handler change.
For **every app**, open/print file parameters, saves (`kfil`), move/duplicate destinations, file creation properties
and nested file objects pass the shared ProtectedPaths checks. Protected files cannot be opened or printed;
writes, deletes, moves and renames also refuse protected ancestors. New names are checked against the resulting
path. System Events property-list writes and Finder folder renames receive the same checks. File parameters must
resolve locally from their descriptors: unknown, relative and indirect file objects are refused rather than
asking an app to resolve them. Setting path/file properties (including TextEdit's `path`, code `ppth`, and bulk
property records) checks the new value as a write destination and refuses unresolved values. Text encodings
(including UTF-16, international and styled text) are coerced to Unicode before checking. Local POSIX paths,
the current user's `~`, local file URLs and absolute HFS paths on mounted volumes resolve without app events.
Known file parameters, identified by keyword and the app's scripting dictionary where available, refuse unresolved
path text, including relative strings containing `/` or `:`. Unknown bookmark/FSSpec descriptors and aliases that
cannot resolve are refused in writes. Nested text naming a protected file is also refused, including HFS text and
relative POSIX text interpreted from `/` even in parameters the dictionary does not identify as files. Ordinary body text such
as `/`, `~5 minutes`, malformed file URLs and containing directories remains usable. Setting Finder's window
`target` is navigation and may point at home, but its text is still checked for protected access.
Saves without an explicit resolvable filename are refused.
Quits and closes that could save documents require `saving no`, including document windows and unresolved close
targets. Apps whose bundle dictionary defines `close` without a `saving` parameter (including Finder) can close without it.
Missing definitions keep the save guard; a dictionary including `CocoaStandard.sdef` is treated as supporting saves.
Any explicit `saving in` path is still checked. Destinations that contain protected descendants are refused because an event could insert
a protected item there. The scripting gate also retains its additional shell startup locations
(fish/zsh configuration and system startup files). These execution event checks are not a filesystem sandbox;
other operations in these apps still have power equivalent to a shell.

Apps must already be running and finished launching in a single process; neither the Automation preflight nor the
host launches them. Delivery uses that process's PID so an app quitting between a check and delivery cannot be
relaunched by its bundle-ID address. Asynchronous app events are refused because their handling cannot be checked
before the script continues.

Before execution, before each event to an app and after its send returns (including named System Events process
targets), the parent checks that app's window `AXDocument` and `AXURL` values through Accessibility. It compares the
AX window count with all windows reported by `CGWindowListCopyWindowInfo(.optionAll)`, including other
Spaces and full screen, and refuses mismatches. It checks document/URL values in window descendants and every tab
exposed by AX tab groups or `AXTabs`. A tab without a readable URL/document refuses the app; Safari also requires a
tab inventory for every window. If any checked value identifies a protected file, the
whole app is refused until a person closes that document. This covers reading a document already open and editing
its contents followed by autosave, even when the Apple event names no path. An unreadable window list or document
attribute, incomplete tab inventory or exhausted traversal budget also refuses the event. The host terminates on a
failed post-send check before returning the reply to the script; the parent discards all earlier output.
The disposable host asks the parent afresh through a private local socket; it
does not need its own Accessibility grant. These checks inspect the current windows and cannot make the check and
an app's later handling of an event atomic with a person's concurrent actions.

AX cannot establish which scripted document or tab a window backs. Before each event using document/tab object
specifiers (including collections, nested properties, dictionary-defined document subclasses and current-document/tab
properties), the host therefore asks the app itself for its complete file inventory. This is one read-only `get`
event for paths only, sent through the same policy, Automation, PID and before/after AX gates; its reply never reaches
the script. The host reads the app's local scripting dictionary once per script run to select a readable document
`path` (`ppth`), `file`, or URL property. TextEdit and Preview expose `ppth`; Safari exposes `pURL` and is queried for
the URL of every tab of every window, covering background tabs as well as the active document.

Every returned file must resolve locally and pass ProtectedPaths; Safari file URLs receive the same check, while
ordinary absolute web URLs are allowed. Explicit no-file values for untitled, never-saved documents are allowed.
The document count must equal the checked AX/CG window inventory, including native document tabs; Safari's nested
tab counts must match the checked tab counts for all windows. Counts and the pinned PID must stay consistent across
the inventory query. Missing or unreadable properties, unresolved values and mismatched counts keep the existing
document/tab-reference refusal. Thus `text of document 1` and `close tab 1` work only with a complete, safe inventory.
The host re-establishes that inventory before every such event, so opens, makes, closes, saves and concurrent changes
cannot reuse an earlier script inventory. The post-send AX recheck still discards the script's output if a protected
document appears. Window and other app automation remains subject to the checks above.

Safari's `sfri/dojs` and Chrome's `CrSu/ExJa` require `web.eval_allowed`, even through `mac_script`. JavaScript text
containing a `file:` URL (case-insensitive) is refused even with that grant. This literal check is not a JavaScript
sandbox: arbitrary code can construct strings at runtime, and the evaluation grant remains broad. Document and tab
checks still apply before and after these events.

macOS must also grant MacMCP Automation access to each app. Without the grant a script fails instead of raising a
consent prompt that nobody answers. A person at the screen approves the first use per app (`request_consent: true`).
The host performs the non-prompting grant check on each actual event target and caches successful checks for that
host run, so an indirect target cannot raise a prompt without that opt-in. Script errors retain their actual error
number, including `-1743` for authorization failures. `mac_doctor` lists the grant state for each allowed app. The host
uses the existing `MacMCPAgent` binary in MacMCP.app, so the current build and signing steps need no extra bundled
executable. Only DEBUG builds may fall back to a host in the source worktree's build directory; release builds
require the running executable to be MacMCPAgent.
