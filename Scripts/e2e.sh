#!/bin/sh
# End-to-end tests: launch a small Metal app and measure it the way MetalCap does.
# They need a logged-in session with the display on, so they run only locally, not in CI.
set -e
cd "$(dirname "$0")/.."

swift build
BIN="$(swift build --show-bin-path)"
# One test at a time: probe windows from parallel tests would cover each other,
# and macOS stops drawing a window that is fully covered.
METALCAP_PROBE="$BIN/MetalCapProbe" METALCAP_CLI="$BIN/MetalCap" swift test --no-parallel --filter MetalCapEndToEndTests
