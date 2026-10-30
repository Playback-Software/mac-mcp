# The install transaction behind scripts/build.sh: one installer at a time, a journal, the swap, rollback, and recovery
# of a swap that was cut short. Sourced, not run. The caller sets APP and CLI (and STAGED_APP / STAGED_CLI before
# swap_in) and runs install_init. scripts/test-install-swap.sh exercises all of it against temp directories.
#
# On disk, next to the install:
#   MacMCP.app.previous  mac-mcp.previous   the known-good copies while a swap is in flight
#   .MacMCP-install.state                    "<phase> <had_app> <had_cli> [<restart>]", from the first change to the
#                                            commit, or until a rollback has fully succeeded
#   .MacMCP-install.lock/pid                 the installer that holds the lock (mkdir is atomic)
#
# A .previous copy is only ever deleted by the commit, or after checking that the live copy is sound without it.
# The traps are set by the caller at top level (zsh runs an EXIT trap set inside a function when the function
# returns, not when the shell exits):
#   trap install_cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP

install_init() {
  PREV="$APP.previous"
  CLI_PREV="$CLI.previous"
  INSTALL_LOCK="${APP:h}/.MacMCP-install.lock"
  INSTALL_STATE="${APP:h}/.MacMCP-install.state"
  INSTALL_PHASE=idle   # idle | swap | verify | committing | rollback: what an interrupt has to undo
  LOCK_HELD=0
  HAD_APP=0
  HAD_CLI=0
  NEEDS_RESTART=0
}

# Whether a copy is sound enough to keep running. Overridden in tests.
app_ok() { codesign --verify --strict "$1" >/dev/null 2>&1 && [[ -x "$1/Contents/MacOS/MacMCPAgent" ]] }
cli_ok() { [[ -x "$1" ]] && codesign --verify --strict "$1" >/dev/null 2>&1 && [[ "$("$1" version 2>/dev/null)" == "mac-mcp "* ]] }
# Starts the agent from the files now in place. Overridden in tests.
restart_agent() { "$CLI" install }
# Called between the steps of the swap; the tests stop the installer here.
install_hook() { : }

# MARK: Lock

# Takes the install lock, or says who has it and returns 1. A lock whose installer is dead is removed first.
install_lock() {
  local holder stale i
  mkdir -p "${INSTALL_LOCK:h}" || return 1
  for i in 1 2 3; do
    if mkdir "$INSTALL_LOCK" 2>/dev/null; then
      print -r -- $$ > "$INSTALL_LOCK/pid"
      LOCK_HELD=1
      return 0
    fi
    holder=$(<"$INSTALL_LOCK/pid" 2>/dev/null) || holder=""
    if [[ -z $holder ]]; then   # created a moment ago, PID not written yet (or its installer died before writing it)
      sleep 1
      holder=$(<"$INSTALL_LOCK/pid" 2>/dev/null) || holder=""
    fi
    if [[ -n $holder ]] && kill -0 "$holder" 2>/dev/null; then
      print -u2 "build.sh: another install is running (pid $holder). Wait for it; if it is gone, remove $INSTALL_LOCK."
      return 1
    fi
    # Its installer is dead. Take the lock over by renaming it away: of several waiters, one rename succeeds. If what
    # was renamed turns out to be a newer holder's lock, give it back.
    stale="$INSTALL_LOCK.stale.$$"
    if mv "$INSTALL_LOCK" "$stale" 2>/dev/null; then
      if [[ "$(<"$stale/pid" 2>/dev/null)" == "$holder" ]]; then
        rm -rf "$stale"
      else
        mv "$stale" "$INSTALL_LOCK" 2>/dev/null || rm -rf "$stale"
      fi
    fi
  done
  print -u2 "build.sh: could not take the install lock $INSTALL_LOCK."
  return 1
}

install_unlock() {
  (( LOCK_HELD )) && rm -rf "$INSTALL_LOCK"
  LOCK_HELD=0
  return 0
}

# MARK: Journal and rollback

write_state() {   # phase [restart]
  print -r -- "$1 $HAD_APP $HAD_CLI${2:+ $2}" > "$INSTALL_STATE.tmp" && mv -f "$INSTALL_STATE.tmp" "$INSTALL_STATE"
}

# Puts the previous files back in place of the new ones (it does not restart the agent). A missing .previous means
# the live copy is the only one there is, so it is left alone. A file that wasn't there before is removed, and a
# removal that fails fails the rollback too: the new file would otherwise stay beside the restored one with no journal
# to say so. Safe to run again after being cut short.
rollback_files() {
  local rc=0
  if (( HAD_APP )); then
    if [[ -e $PREV ]]; then rm -rf "$APP" && mv "$PREV" "$APP" || rc=1; fi
  else
    rm -rf "$APP" || rc=1
  fi
  if (( HAD_CLI )); then
    if [[ -e $CLI_PREV ]]; then mv -f "$CLI_PREV" "$CLI" || rc=1; fi
  else
    rm -f "$CLI" "$CLI_PREV" || rc=1
  fi
  return $rc
}

# The live copy, sound or not, against a .previous that no journal explains (a run killed before it wrote one, or an
# older build.sh). Nothing is deleted unless what stays is sound.
settle_leftover() {   # live previous check-function
  local live=$1 prev=$2 check=$3
  [[ -e $prev ]] || return 0
  if [[ ! -e $live ]]; then
    print -u2 "build.sh: $live is missing; restoring it from $prev."
    mv "$prev" "$live"
  elif $check "$live"; then
    print -u2 "build.sh: removing the leftover $prev ($live is sound)."
    rm -rf "$prev"
  elif $check "$prev"; then
    print -u2 "build.sh: $live is damaged; restoring it from $prev."
    rm -rf "$live" && mv "$prev" "$live"
  else
    print -u2 "build.sh: neither $live nor $prev passes its checks. Both are left as they are; fix them by hand."
    return 1
  fi
}

# Run first, under the lock: finishes whatever an interrupted install left half done. A journal, whatever its
# phase, means a restoration is owed: it is retried before any leftover backup is treated as disposable, since
# the live copy may be the new build that a half-done rollback left in place (sound on its own, wrong beside the
# restored app). The journal is kept until the restoration has fully succeeded.
recover_install() {
  local phase had_app had_cli restart
  rm -f "$INSTALL_STATE.tmp" "$CLI_PREV.tmp"
  rm -rf -- "${APP:h}"/.MacMCP-stage.*(N) "${CLI:h}"/.mac-mcp.new.*(N)   # staging litter; nobody else is installing
  if [[ -e $INSTALL_STATE ]]; then
    read -r phase had_app had_cli restart < "$INSTALL_STATE" || true
    HAD_APP=${had_app:-0}
    HAD_CLI=${had_cli:-0}
    if [[ $phase == rollback ]]; then
      print -u2 "build.sh: an earlier install could not be fully rolled back; finishing that first."
    else
      print -u2 "build.sh: an earlier install stopped during its ${phase:-swap}; putting the previous version back first."
    fi
    if ! rollback_files; then
      print -u2 "build.sh: could not put the previous files back. Left as they are: $APP.previous, $CLI.previous."
      return 1   # the journal stays: the next run tries again
    fi
    rm -f "$INSTALL_STATE"
    # A new agent was started from the files that were just replaced.
    [[ $phase == verify || ${restart:-0} == 1 ]] && NEEDS_RESTART=1
    return 0
  fi
  settle_leftover "$APP" "$PREV" app_ok || return 1
  settle_leftover "$CLI" "$CLI_PREV" cli_ok || return 1
}

# MARK: Swap

# Moves STAGED_APP and STAGED_CLI into place, keeping the files they replace as .previous. Returns 0 with the phase
# at `verify`; on any failure puts the old files back (keeping the journal if that doesn't fully succeed) and returns 1.
swap_in() {
  if [[ -e $PREV || -e $CLI_PREV ]]; then
    print -u2 "build.sh: $PREV or $CLI_PREV exists and was not recovered. Nothing was changed."
    return 1
  fi
  HAD_APP=0
  HAD_CLI=0
  [[ -e $APP ]] && HAD_APP=1
  [[ -e $CLI ]] && HAD_CLI=1
  INSTALL_PHASE=swap
  if ! write_state swap; then
    INSTALL_PHASE=idle
    print -u2 "build.sh: could not write $INSTALL_STATE. Nothing was changed."
    return 1
  fi
  install_hook journaled
  # The backup is renamed into place, so an interruption never leaves a partial one that would be trusted.
  if (( HAD_CLI )); then
    cp -p "$CLI" "$CLI_PREV.tmp" && mv -f "$CLI_PREV.tmp" "$CLI_PREV" || { swap_failed "could not keep a copy of the current CLI"; return 1 }
  fi
  install_hook cli_backed_up
  if (( HAD_APP )); then
    mv "$APP" "$PREV" || { swap_failed "could not move the current app aside"; return 1 }
  fi
  install_hook app_moved_aside
  mv "$STAGED_APP" "$APP" || { swap_failed "could not move the new app into place"; return 1 }
  install_hook app_in_place
  mv -f "$STAGED_CLI" "$CLI" || { swap_failed "could not move the new CLI into place"; return 1 }
  install_hook swapped
  INSTALL_PHASE=verify
  write_state verify || true
  return 0
}

swap_failed() {
  print -u2 "build.sh: $1; restoring the previous install."
  revert_install || print -u2 "build.sh: could not put everything back; the next build.sh run finishes that first."
}

# The new install proved itself: forget the old one. The journal goes first, so a stop in between leaves a sound live
# copy with a leftover that recover_install checks before removing.
commit_install() {
  INSTALL_PHASE=committing
  rm -f "$INSTALL_STATE"
  rm -rf "$PREV" "$CLI_PREV"
  INSTALL_PHASE=idle
}

# The new install did not prove itself: the old one goes back. The journal is forgotten only once both files are
# back. A restoration that fails leaves it in the `rollback` phase, recording whether the agent was started on the
# new files, so the next run finishes the rollback before anything else rather than finding a sound-looking new
# CLI beside a disposable backup. Returns 1 if the files could not all be restored.
revert_install() {
  local restart=0
  [[ $INSTALL_PHASE == verify ]] && restart=1
  INSTALL_PHASE=rollback
  if rollback_files; then
    rm -f "$INSTALL_STATE" "$CLI_PREV.tmp"
    INSTALL_PHASE=idle
    return 0
  fi
  write_state rollback $restart || print -u2 "build.sh: could not record the unfinished rollback in $INSTALL_STATE."
  return 1
}

# EXIT trap. An interrupt (Ctrl-C, kill) during the swap or the health check puts the previous install back; any
# other time there is nothing of the install's to undo (a rollback that already failed keeps its journal for the
# next run). Always releases the lock.
install_cleanup() {
  local rc=$? phase=$INSTALL_PHASE
  trap - EXIT INT TERM HUP
  if [[ $phase == swap || $phase == verify ]]; then
    print -u2 "build.sh: stopped during the install; restoring the previous version."
    if revert_install; then
      # In `verify` the agent may already be running the new files.
      [[ $phase == verify ]] && { restart_agent >/dev/null 2>&1 || true; }
    else
      print -u2 "build.sh: could not restore everything; $APP.previous and $CLI.previous are kept, and the next build.sh run finishes the rollback first."
    fi
  elif [[ $phase == rollback ]]; then
    print -u2 "build.sh: the previous install could not be fully restored; the next build.sh run finishes that first."
  fi
  [[ -n ${STAGE:-} ]] && rm -rf "$STAGE"
  [[ -n ${STAGED_CLI:-} ]] && rm -f "$STAGED_CLI"
  install_unlock
  exit $rc
}
