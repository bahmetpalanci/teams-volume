#!/bin/bash

PLIST_NAME="com.teamsvolume.app"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_NAME.plist"

launchctl unload "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH"

pkill -f TeamsVolume 2>/dev/null || true

echo "TeamsVolume uninstalled."
