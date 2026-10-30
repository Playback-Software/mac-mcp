#!/bin/sh
# The "build" task: passes only once the old name is gone from the project. The name is assembled here so that a
# project-wide Find and Replace (which the task asks for) can't rewrite this check along with the sources.
cd "$(dirname "$0")"
old="OLD""_NAME"
if grep -rq "$old" src README.md; then echo FAIL > build-output.txt; else echo OK > build-output.txt; fi
