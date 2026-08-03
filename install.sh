#!/usr/bin/env bash
# Installs the built app to ~/Applications. With --login, also registers a LaunchAgent so the
# widget starts at login and is kept alive.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/ClaudeUsageWidget.app"
[ -d "$APP" ] || { echo "build first: ./build.sh"; exit 1; }

DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/ClaudeUsageWidget.app"
cp -R "$APP" "$DEST/"
echo "installed → $DEST/ClaudeUsageWidget.app"

if [ "${1:-}" = "--login" ]; then
    PLIST="$HOME/Library/LaunchAgents/ai.yahelh.claude-usage-widget.plist"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>ai.yahelh.claude-usage-widget</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/ClaudeUsageWidget.app/Contents/MacOS/ClaudeUsageWidget</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    echo "login agent → $PLIST"
fi
