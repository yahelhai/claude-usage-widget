#!/usr/bin/env bash
# Builds the widget app and the probe/feeder tool with swiftc (no Xcode, no SwiftPM).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build

echo "· building widget"
swiftc -O Sources/*.swift -o build/ClaudeUsageWidget

echo "· building probe/feeder tool"
swiftc -O Tools/main.swift Sources/ClaudeVisibility.swift Sources/BridgeProtocol.swift -o build/probe

echo "· assembling app bundle"
APP="build/ClaudeUsageWidget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp build/ClaudeUsageWidget "$APP/Contents/MacOS/ClaudeUsageWidget"
cp Info.plist "$APP/Contents/Info.plist"
codesign -s - --force "$APP"

echo "done → $APP"
