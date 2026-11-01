#!/bin/bash
# lot — League of Trackpad: build from source and start at login.
# Requires Xcode Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"

LABEL="io.github.and-riu.lot"
APP="$HOME/Library/Application Support/lot_macOS"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/lot_macOS.log"

command -v swiftc >/dev/null || { echo "swiftc not found. Run: xcode-select --install"; exit 1; }

echo "Building…"
mkdir -p build "$APP"
swiftc -O Sources/lot.swift -o build/lot
cp build/lot "$APP/lot"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/lot</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 2
echo "--- log:"; tail -3 "$LOG"
echo
echo "If you see NO_EVENT_TAP: System Settings → Privacy & Security → Accessibility → enable «lot»."
echo "(If it isn't listed: press +, then Cmd+Shift+G and paste: $APP/lot)"
echo "lot retries on its own every ~30 s."
