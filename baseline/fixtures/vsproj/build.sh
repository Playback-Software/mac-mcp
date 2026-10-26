#!/bin/sh
# The "build" task: passes only once OLD_NAME is gone from the project.
cd "$(dirname "$0")"
if grep -rq OLD_NAME src README.md; then echo FAIL > build-output.txt; else echo OK > build-output.txt; fi
