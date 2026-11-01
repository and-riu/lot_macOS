#!/bin/bash
# lot — League of Trackpad: stop and remove.
LABEL="io.github.and-riu.lot"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x lot 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Application Support/lot_macOS"
echo "lot removed. (You can also remove it from System Settings → Privacy & Security → Accessibility.)"
