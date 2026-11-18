#!/bin/bash
#
# test.sh — run BTSwitch's unit tests without Xcode.
#
# Compiles the pure protocol/parsing logic (BTSwitch/Protocol.swift) together
# with Tests/main.swift into a small executable and runs it.
# Requires Xcode Command Line Tools (xcode-select --install).

set -euo pipefail

cd "$(dirname "$0")"

OUT_DIR="build/tests"
mkdir -p "$OUT_DIR"

echo "==> Compiling tests…"
xcrun swiftc \
    -target "$(uname -m)-apple-macos13.0" \
    -o "$OUT_DIR/BTSwitchTests" \
    BTSwitch/Protocol.swift \
    Tests/main.swift

echo "==> Running tests…"
"$OUT_DIR/BTSwitchTests"
