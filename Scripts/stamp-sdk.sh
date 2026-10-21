#!/bin/sh
# Records the SDK the binary was compiled with. SwiftPM's build system with the Command Line Tools
# records the deployment target (14.0) instead, and macOS then shows the app in its old, compatibility
# look; with the real SDK version it gets the current look (Liquid Glass on macOS 26 and later).
# Usage: Scripts/stamp-sdk.sh <binary>
set -e
SDK="$(xcrun --show-sdk-version)"
vtool -set-build-version macos 14.0 "$SDK" -replace -output "$1" "$1" 2>/dev/null
