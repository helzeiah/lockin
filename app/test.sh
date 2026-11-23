#!/bin/bash
# Runs lockin's tests, no Xcode needed:
#   the plan parser and the app's logic (Swift, headless, against a temporary data folder), and the helper (Python).
set -euo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT

swiftc -O -parse-as-library app/Sources/PlanParser.swift app/Tests/PlanParserTests.swift -o "$tmp/parser-tests"
"$tmp/parser-tests"

# The app's sources without its @main entry point, plus the test runner's.
sed 's/^@main$//' app/Sources/App.swift > "$tmp/AppNoMain.swift"
sources=()
for f in app/Sources/*.swift; do [[ "$f" == "app/Sources/App.swift" ]] || sources+=("$f"); done
swiftc -swift-version 5 -parse-as-library "${sources[@]}" "$tmp/AppNoMain.swift" app/Tests/EngineTests.swift -o "$tmp/engine-tests"
"$tmp/engine-tests"

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s app/Tests -p 'test_*.py' -q
