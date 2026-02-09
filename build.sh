#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building TeamsVolume..."
mkdir -p TeamsVolume.app/Contents/MacOS
swiftc TeamsVolume.swift -o TeamsVolume.app/Contents/MacOS/TeamsVolume \
  -framework Cocoa -framework CoreAudio -framework AudioToolbox -O

# Sign with stable ad-hoc identity so TCC permission persists
codesign --force --deep --sign - TeamsVolume.app

echo "Done! Run with: open TeamsVolume.app"
echo "Or install as login item with: ./install.sh"
