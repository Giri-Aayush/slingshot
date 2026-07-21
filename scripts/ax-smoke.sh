#!/bin/bash
# Accessibility smoke test: verifies the live app's menu bar surface.
# Requirements: Slingshot running, and your terminal granted Accessibility
# (System Settings, Privacy and Security, Accessibility).
set -euo pipefail

pgrep -x Slingshot >/dev/null || { echo "FAIL  Slingshot is not running"; exit 1; }
echo "PASS  Slingshot process is running"

osascript <<'AS'
tell application "System Events"
    tell process "Slingshot"
        if not (exists menu bar 2) then error "no status item found"
        click menu bar item 1 of menu bar 2
        delay 0.3
        set names to name of menu items of menu 1 of menu bar item 1 of menu bar 2
        key code 53 -- escape, close the menu
        return names
    end tell
end tell
AS
echo "PASS  status item opened and its menu enumerated (items printed above)"

for expected in "Check for Updates" "Start at Login" "Reset trusted Macs" "Show Welcome" "Show Log" "Quit Slingshot"; do
    echo "      expect menu to contain: $expected"
done
echo "Compare the printed names with the expectations above."
