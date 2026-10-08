#!/bin/sh
# Generate, bundle, package, then run the whole test suite. Stops on the first failure.
set -e
cd "$(dirname "$0")"
python3 tools/build.py
python3 tools/build.py --check
python3 tools/check_forward_refs.py
for f in build/*/driver.lua; do luac5.1 -p "$f"; done
lua5.1 tests/run_all.lua
