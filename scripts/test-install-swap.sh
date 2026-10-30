#!/bin/zsh
# Exercises scripts/install-swap.zsh (the install transaction behind build.sh) against temp directories with fake
# app and CLI files: the swap, rollback, interruption by a crash or a signal at every step, recovery on the next run,
# and the lock. It signs nothing, builds nothing and never touches ~/Applications, ~/.local/bin or launchd.
#
#   scripts/test-install-swap.sh        exits 0 if every check passed
set -uo pipefail
LIB="${0:A:h}/install-swap.zsh"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mac-mcp-install-test.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
failures=0
checks=0

check() {   # description, actual, expected
  checks=$((checks + 1))
  if [[ "$2" == "$3" ]]; then print -r -- "ok   - $1"; else print -r -- "FAIL - $1: got <$2>, wanted <$3>"; failures=$((failures + 1)); fi
}

# A fresh scene: an install of v1 and a staged v2, each app a directory with a `version` file (and an `ok` file when
# it passes the soundness check), each CLI a file whose content is its version ("bad" fails the check).
scene() {
  T="$ROOT/$1"
  APP="$T/Applications/MacMCP.app"
  CLI="$T/bin/mac-mcp"
  mkdir -p "${APP:h}" "${CLI:h}"
  mkapp "$APP" v1
  print -r -- v1 > "$CLI"
  stage_new
  cat > "$T/fake.zsh" <<EOF
app_ok() { [[ -f "\$1/ok" ]] }
cli_ok() { [[ -f "\$1" && "\$(<"\$1")" != bad ]] }
restart_agent() { print restarted >> "$T/log" }
EOF
  : > "$T/log"
}
mkapp() { mkdir -p "$1" && print -r -- "$2" > "$1/version" && { [[ ${3:-} == bad ]] || : > "$1/ok" } }
# The staged build. Its names avoid the patterns recover_install sweeps (a real run stages after recovering).
stage_new() {
  rm -rf "$T/new" "$T/bin/new-cli"
  mkapp "$T/new/MacMCP.app" v2
  print -r -- v2 > "$T/bin/new-cli"
}
app_version() { [[ -e "$APP/version" ]] && cat "$APP/version" || print -r -- none }
cli_version() { [[ -e "$CLI" ]] && cat "$CLI" || print -r -- none }
exists() { [[ -e "$1" ]] && print yes || print no }

# Runs `body` in a separate zsh with the library loaded, the way build.sh runs it. `traps` adds build.sh's traps.
child() {   # traps(yes|no) body
  local traps=$1 body=$2
  zsh -f -c "
    source '$LIB'
    APP='$APP'; CLI='$CLI'; STAGED_APP='$T/new/MacMCP.app'; STAGED_CLI='$T/bin/new-cli'; STAGE='$T/new'
    install_init
    source '$T/fake.zsh'
    if [[ $traps == yes ]]; then trap install_cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP; fi
    $body
  " >"${OUT:-$T/out}" 2>&1
}
steps=(journaled cli_backed_up app_moved_aside app_in_place swapped)

# --- A normal install: swap, then commit forgets the old copies and the journal.
scene happy
child no 'install_lock && recover_install && swap_in'
check "the swap installs the new app and CLI" "$(app_version)$(cli_version)" v2v2
check "the swap keeps the old app next to the new one until commit" "$(cat "$APP.previous/version")" v1
check "the swap keeps the old CLI next to the new one until commit" "$(cat "$CLI.previous")" v1
check "the journal says verify" "$(cat "${APP:h}/.MacMCP-install.state")" "verify 1 1"
child no 'commit_install'
check "commit removes the old copies and the journal" "$(exists "$APP.previous")$(exists "$CLI.previous")$(exists "${APP:h}/.MacMCP-install.state")" nonono
check "…and leaves the new install" "$(app_version)$(cli_version)" v2v2

# --- A swap step fails: the old install comes back at once.
scene failstep
rm -rf "$T/new/MacMCP.app"
child no 'install_lock && recover_install && { swap_in || echo "swap failed rc=$?"; }'
check "a failed swap restores the app" "$(app_version)" v1
check "a failed swap restores the CLI" "$(cli_version)" v1
check "a failed swap leaves no backups or journal" "$(exists "$APP.previous")$(exists "$CLI.previous")$(exists "${APP:h}/.MacMCP-install.state")" nonono

# --- The installer dies (kill -9, power loss: no traps) at each step: the next run puts everything back first.
for step in $steps; do
  scene "crash-$step"
  child no "install_hook() { [[ \$1 == $step ]] && exit 99; return 0 }; install_lock; recover_install; swap_in"
  check "crash at $step: the installer died holding the lock" "$(exists "${APP:h}/.MacMCP-install.lock")" yes
  child no 'install_lock && recover_install && echo recovered'
  check "crash at $step: the next run takes the dead installer's lock and recovers" "$(tail -1 "$T/out")" recovered
  check "crash at $step: the app is the old one again" "$(app_version)" v1
  check "crash at $step: the CLI is the old one again" "$(cli_version)" v1
  check "crash at $step: no backups or journal left" \
    "$(exists "$APP.previous")$(exists "$CLI.previous")$(exists "${APP:h}/.MacMCP-install.state")" nonono
  stage_new
  child no 'install_lock && recover_install && swap_in && commit_install'
  check "crash at $step: and a later install goes through" "$(app_version)$(cli_version)" v2v2
done

# --- Ctrl-C or kill at each step of the swap: the traps put the old install back with no help from a later run.
for step in $steps; do
  scene "term-$step"
  child yes "install_hook() { [[ \$1 == $step ]] && kill -TERM \$\$; return 0 }; install_lock; recover_install; swap_in; echo unreachable"
  check "signal at $step: the app is the old one" "$(app_version)" v1
  check "signal at $step: the CLI is the old one" "$(cli_version)" v1
  check "signal at $step: no backups, journal, lock or staging left" \
    "$(exists "$APP.previous")$(exists "$CLI.previous")$(exists "${APP:h}/.MacMCP-install.state")$(exists "${APP:h}/.MacMCP-install.lock")$(exists "$T/new")$(exists "$T/bin/new-cli")" nononononono
  check "signal at $step: the agent was not restarted (it never changed)" "$(cat "$T/log")" ""
done

# --- Ctrl-C while waiting for the new agent: the old files come back and the agent is restarted on them.
scene term-verify
child yes 'install_lock; recover_install; swap_in; kill -TERM $$; echo unreachable'
check "signal during the health check: the app is the old one" "$(app_version)$(cli_version)" v1v1
check "signal during the health check: the agent is restarted" "$(cat "$T/log")" restarted
check "signal during the health check: nothing left behind" \
  "$(exists "$APP.previous")$(exists "$CLI.previous")$(exists "${APP:h}/.MacMCP-install.state")$(exists "${APP:h}/.MacMCP-install.lock")" nononono

# --- A normal exit after commit leaves the new install alone.
scene committed
child yes 'install_lock; recover_install; swap_in; commit_install; exit 0'
check "a committed install survives the exit trap" "$(app_version)$(cli_version)$(exists "$APP.previous")" v2v2no

# --- Reverting after a failed health check.
scene revert
child no 'install_lock; recover_install; swap_in; revert_install; echo "phase=$INSTALL_PHASE"'
check "revert_install restores both" "$(app_version)$(cli_version)$(exists "$APP.previous")$(exists "${APP:h}/.MacMCP-install.state")" v1v1nono

# --- A rollback that fails half way (the app is back, the CLI is not) keeps its journal. Without it the next run
# would find the new CLI sound on its own, throw its backup away and leave a mixed install.
failing_cli_restore() {   # writes a `mv` that refuses to put the CLI backup back, for the child to source
  cat > "$T/failmv.zsh" <<EOF
mv() {
  if [[ "\$*" == *"$CLI.previous $CLI" ]]; then print -u2 "mv: injected failure restoring the CLI"; return 1; fi
  command mv "\$@"
}
EOF
}
scene revert-partial
failing_cli_restore
child no "source '$T/failmv.zsh'; install_lock; recover_install; swap_in; revert_install; echo \"rc=\$? phase=\$INSTALL_PHASE\""
check "a rollback whose CLI restore fails says so" "$(tail -1 "$T/out")" "rc=1 phase=rollback"
check "…the app is back but the CLI is still the new one" "$(app_version)$(cli_version)" v1v2
check "…the CLI backup is kept" "$(cat "$CLI.previous")" v1
check "…and the journal records the unfinished rollback, and that the agent was started" "$(cat "${APP:h}/.MacMCP-install.state")" "rollback 1 1 1"
child no 'install_lock && recover_install && echo "recovered restart=$NEEDS_RESTART"'
check "the next run finishes the rollback instead of trusting the new CLI" "$(tail -1 "$T/out")" "recovered restart=1"
check "…so the CLI is the old one again" "$(app_version)$(cli_version)" v1v1
check "…with no backups or journal left" "$(exists "$APP.previous")$(exists "$CLI.previous")$(exists "${APP:h}/.MacMCP-install.state")" nonono
stage_new
child no 'install_lock && recover_install && swap_in && commit_install'
check "…and a later install goes through" "$(app_version)$(cli_version)" v2v2

# --- The same when a swap step fails and its rollback can't finish.
scene swapfail-partial
failing_cli_restore
rm -f "$T/bin/new-cli"
child no "source '$T/failmv.zsh'; install_lock; recover_install; swap_in; echo \"rc=\$? phase=\$INSTALL_PHASE\""
check "a failed swap whose rollback fails keeps the rollback phase" "$(tail -1 "$T/out")" "rc=1 phase=rollback"
check "…and its journal" "$(cat "${APP:h}/.MacMCP-install.state")" "rollback 1 1 0"
check "…and the CLI backup" "$(exists "$CLI.previous")" yes
child no 'install_lock && recover_install && echo "recovered restart=$NEEDS_RESTART"'
check "the next run finishes that rollback" "$(tail -1 "$T/out")$(app_version)$(cli_version)" "recovered restart=0v1v1"
check "…leaving no backups or journal" "$(exists "$APP.previous")$(exists "$CLI.previous")$(exists "${APP:h}/.MacMCP-install.state")" nonono

# --- And when the rollback is the exit trap's, after a signal during the health check.
scene term-verify-partial
failing_cli_restore
child yes "source '$T/failmv.zsh'; install_lock; recover_install; swap_in; kill -TERM \$\$; echo unreachable"
check "a signal during the health check whose rollback fails keeps the journal" "$(cat "${APP:h}/.MacMCP-install.state")" "rollback 1 1 1"
check "…does not restart the agent on mixed files" "$(cat "$T/log")" ""
check "…and releases the lock" "$(exists "${APP:h}/.MacMCP-install.lock")" no
child no 'install_lock && recover_install && echo "recovered restart=$NEEDS_RESTART"'
check "the next run finishes the trap's rollback and knows to restart the agent" "$(tail -1 "$T/out")$(app_version)$(cli_version)" "recovered restart=1v1v1"

# --- A rollback that fails again on the next run keeps waiting, rather than giving up on the backups.
scene rollback-stuck
failing_cli_restore
child no "source '$T/failmv.zsh'; install_lock; recover_install; swap_in; revert_install"
child no "source '$T/failmv.zsh'; install_lock; recover_install; echo \"rc=\$?\""
check "a rollback that fails again is reported" "$(tail -1 "$T/out")" rc=1
check "…and the journal and backup are still there" "$(cat "${APP:h}/.MacMCP-install.state")$(exists "$CLI.previous")" "rollback 1 1 1yes"
child no 'install_lock && recover_install && echo recovered'
check "…until a run can finish it" "$(tail -1 "$T/out")$(cli_version)$(exists "$CLI.previous")" recoveredv1no

# --- A rollback that can't remove a file that wasn't there before keeps its journal too: an upgrade on a Mac with no
# CLI, whose new CLI won't go, and a first install, whose new app won't.
failing_removal() {   # path: writes an `rm` that refuses to remove it, for the child to source
  cat > "$T/failrm.zsh" <<EOF
rm() {
  if (( \${@[(Ie)$1]} )); then print -u2 "rm: injected failure removing $1"; return 1; fi
  command rm "\$@"
}
EOF
}
scene revert-new-cli
rm -f "$CLI"
failing_removal "$CLI"
child no "source '$T/failrm.zsh'; install_lock; recover_install; swap_in; revert_install; echo \"rc=\$? phase=\$INSTALL_PHASE\""
check "a rollback that can't remove the new CLI says so" "$(tail -1 "$T/out")" "rc=1 phase=rollback"
check "…the app is back but the new CLI is still there" "$(app_version)$(cli_version)" v1v2
check "…and the journal records the unfinished rollback" "$(cat "${APP:h}/.MacMCP-install.state")" "rollback 1 0 1"
child no 'install_lock && recover_install && echo "recovered restart=$NEEDS_RESTART"'
check "the next run removes the new CLI" "$(tail -1 "$T/out")$(app_version)$(cli_version)" "recovered restart=1v1none"
check "…with no backups or journal left" "$(exists "$APP.previous")$(exists "$CLI.previous")$(exists "${APP:h}/.MacMCP-install.state")" nonono
scene revert-new-app
rm -rf "$APP"
failing_removal "$APP"
child no "source '$T/failrm.zsh'; install_lock; recover_install; swap_in; revert_install; echo \"rc=\$? phase=\$INSTALL_PHASE\""
check "a first install's rollback that can't remove the new app says so" "$(tail -1 "$T/out")" "rc=1 phase=rollback"
check "…the CLI is back but the new app is still there" "$(app_version)$(cli_version)" v2v1
check "…and the journal records the unfinished rollback" "$(cat "${APP:h}/.MacMCP-install.state")" "rollback 0 1 1"
child no "source '$T/failrm.zsh'; install_lock; recover_install; echo \"rc=\$?\""
check "…and keeps it while the removal still fails" "$(tail -1 "$T/out")$(cat "${APP:h}/.MacMCP-install.state")" "rc=1rollback 0 1 1"
child no 'install_lock && recover_install && echo recovered'
check "the next run that can removes the new app" "$(tail -1 "$T/out")$(app_version)$(cli_version)" recoverednonev1
check "…with no backups or journal left" "$(exists "$APP.previous")$(exists "$CLI.previous")$(exists "${APP:h}/.MacMCP-install.state")" nonono

# --- A first install (nothing there before) that is cut short leaves nothing half-installed.
scene fresh
rm -rf "$APP" "$CLI"
child no 'install_hook() { [[ $1 == app_in_place ]] && exit 99; return 0 }; install_lock; recover_install; swap_in'
child no 'install_lock && recover_install'
check "an interrupted first install is removed" "$(app_version)$(cli_version)" nonenone

# --- The journal without its backups must never cost the only copy.
scene only-copy
print "swap 1 1" > "${APP:h}/.MacMCP-install.state"   # as if killed right after the journal was written
print partial > "$CLI.previous.tmp"
child no 'install_lock && recover_install'
check "recovery with nothing to restore keeps the live app and CLI" "$(app_version)$(cli_version)" v1v1
check "recovery drops a half-written backup" "$(exists "$CLI.previous.tmp")" no

# --- A run killed during the health check: files are rolled back and the next run knows to restart the agent.
scene verify-crash
child no 'install_lock; recover_install; swap_in'
child no 'install_lock && recover_install && echo "restart=$NEEDS_RESTART"'
check "a crash during the health check is rolled back" "$(app_version)$(cli_version)" v1v1
check "…and the next run is told the agent may be running the new build" "$(tail -1 "$T/out")" restart=1

# --- Leftovers with no journal (killed before it was written, or an older build.sh).
scene leftover-gone
mv "$APP" "$APP.previous"
child no 'install_lock && recover_install'
check ".previous with no live app is put back" "$(app_version)$(exists "$APP.previous")" v1no
scene leftover-sound
mkapp "$APP.previous" old
print -r -- old > "$CLI.previous"
child no 'install_lock && recover_install'
check "a leftover .previous next to a sound app is removed" "$(app_version)$(exists "$APP.previous")$(cli_version)$(exists "$CLI.previous")" v1nov1no
scene leftover-damaged
rm -rf "$APP"; mkapp "$APP" broken bad
mkapp "$APP.previous" old
print bad > "$CLI"; print -r -- old > "$CLI.previous"
child no 'install_lock && recover_install'
check "a damaged app is replaced from a sound .previous" "$(app_version)$(exists "$APP.previous")" oldno
check "a damaged CLI is replaced from a sound .previous" "$(cli_version)$(exists "$CLI.previous")" oldno
scene leftover-both-bad
rm -rf "$APP"; mkapp "$APP" broken bad
mkapp "$APP.previous" alsobroken bad
child no 'install_lock && recover_install'
check "recovery refuses to guess when both copies are damaged" "$(app_version)$(cat "$APP.previous/version")" brokenalsobroken
check "…and leaves both in place" "$(exists "$APP")$(exists "$APP.previous")" yesyes
scene leftover-cli-gone
rm -f "$CLI"; print -r -- v1 > "$CLI.previous"
child no 'install_lock && recover_install'
check "a missing CLI is restored from .previous" "$(cli_version)$(exists "$CLI.previous")" v1no
scene leftover-stage
mkdir -p "$T/Applications/.MacMCP-stage.abc123/MacMCP.app"
print x > "$T/bin/.mac-mcp.new.4242"
child no 'install_lock && recover_install'
check "stale staging directories and files are cleaned up" "$(exists "$T/Applications/.MacMCP-stage.abc123")$(exists "$T/bin/.mac-mcp.new.4242")" nono

# --- A swap will not start over an unrecovered .previous.
scene guarded
mkapp "$APP.previous" precious
child no 'swap_in; echo "rc=$?"'
check "swap_in refuses while a .previous exists" "$(tail -1 "$T/out")" rc=1
check "…and does not touch it or the live app" "$(cat "$APP.previous/version")$(app_version)" preciousv1

# --- The lock.
scene lock
sleep 30 & holder=$!
mkdir "${APP:h}/.MacMCP-install.lock"; print -r -- $holder > "${APP:h}/.MacMCP-install.lock/pid"
child no 'install_lock; echo "rc=$?"'
check "a live installer's lock is respected" "$(tail -1 "$T/out")" rc=1
check "…and kept, with its PID" "$(cat "${APP:h}/.MacMCP-install.lock/pid")" "$holder"
check "…and the refusal says who holds it" "$(grep -c "pid $holder" "$T/out")" 1
kill $holder 2>/dev/null; wait $holder 2>/dev/null
child no 'install_lock; echo "rc=$?"; echo "pid=$(<"$INSTALL_LOCK/pid")"; echo "me=$$"'
check "the lock of a dead installer is taken over" "$(grep rc= "$T/out")" rc=0
check "…and now names the new installer" "$(grep pid= "$T/out" | cut -d= -f2)" "$(grep me= "$T/out" | cut -d= -f2)"
rm -rf "${APP:h}/.MacMCP-install.lock"; mkdir "${APP:h}/.MacMCP-install.lock"
child no 'install_lock; echo "rc=$?"'
check "a lock that never got a PID is taken over too" "$(tail -1 "$T/out")" rc=0
scene two-installers
OUT="$T/out-first" child no 'install_lock; echo "first rc=$?"; sleep 4' &
first=$!
for _ in {1..40}; do [[ -f "${APP:h}/.MacMCP-install.lock/pid" ]] && break; sleep 0.1; done
child no 'install_lock; echo "second rc=$?"'
check "a second installer is turned away while the first runs" "$(tail -1 "$T/out")" "second rc=1"
wait $first
check "…and the lock stays with the first until it is done" "$(exists "${APP:h}/.MacMCP-install.lock")" yes
child no 'install_lock; echo "rc=$?"; install_unlock; echo "after=$(ls -d "$INSTALL_LOCK" 2>/dev/null | wc -l | tr -d " ")"'
check "release removes the lock" "$(tail -1 "$T/out")" after=0

print
print "$checks checks, $failures failed"
(( failures == 0 ))
