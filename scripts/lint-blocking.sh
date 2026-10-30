#!/bin/zsh
# Fails if agent code blocks a thread in a way that can wedge it. The agent runs on Swift concurrency's small
# cooperative pool, and blocking calls there are how M5 lost 13 minutes:
#   waitUntilExit()           spins a run loop that nothing wakes on a pool thread; use Subprocess
#   .wait() with no timeout   can block forever; use .wait(timeout:)
#   sleep / usleep / Thread.sleep  ties up a pool thread and ignores cancellation; use Task.sleep
#   flock                     can block on another process
#   readDataToEndOfFile       waits for EOF (a long-lived child can hold it forever)
#   queue.sync                waits for a writer (possibly blocked on a peer); await an asynchronous barrier
#   .wait(timeout:/until:/wallTimeout:)  a bounded wait still holds its thread: on the pool, enough concurrent callers
#                             stall every task. Await a continuation, or keep the wait on a dedicated thread or in
#                             synchronous code (the CLI) and say so with lint:allow-blocking
# ScriptHost runs in a separate child; its main thread may read its one request from stdin to EOF. DedicatedThreads
# is the native thread pool itself: its workers' timed waits are what it's for.
# A line can opt out with a `lint:allow-blocking <reason>` comment. Comment lines are ignored.
set -euo pipefail
cd "${0:A:h}/.."
hits=$(grep -rnE 'readDataToEndOfFile\(|waitUntilExit\(|\.wait\(\)|\.wait\((timeout|until|wallTimeout):|Thread\.sleep|(^|[^.A-Za-z_])u?sleep\(|flock\(|[.]sync[[:space:]]*[{(]' \
    Sources/MacMCPCore Sources/MacMCPServer Sources/MacMCPAgent \
  | grep -v 'lint:allow-blocking' \
  | grep -vE 'Sources/MacMCPCore/Act/ScriptHost.swift:[0-9]+:.*FileHandle.standardInput.readDataToEndOfFile' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
if [[ -n "$hits" ]]; then
  print -u2 "Blocking calls in agent code (see scripts/lint-blocking.sh for why and what to use instead):"
  print -u2 -- "$hits"
  exit 1
fi
