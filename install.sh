#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$SCRIPT_DIR/TeamsVolume.app"
PLIST_NAME="com.teamsvolume.app"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

if [ ! -f "$APP_PATH/Contents/MacOS/TeamsVolume" ]; then
    echo "TeamsVolume not found. Building first..."
    bash "$SCRIPT_DIR/build.sh"
fi

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_NAME</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>$APP_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
</plist>
EOF

launchctl load "$PLIST_PATH" 2>/dev/null || true
echo "TeamsVolume installed as login item."
echo "It will start automatically on login."
echo "To uninstall: ./uninstall.sh"
