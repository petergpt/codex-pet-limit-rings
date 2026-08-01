#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CODEX_PET_LIMIT_RINGS_APP:-$HOME/Applications/CodexPetLimitRings.app}"
BIN="$APP/Contents/MacOS/CodexPetLimitRings"
AGENT_DIR="$HOME/Library/LaunchAgents"
AGENT="$AGENT_DIR/com.codex-pet.limit-rings.plist"
OLD_APP="${CODEX_LIMIT_AURA_APP:-$HOME/Applications/CodexLimitAura.app}"
OLD_BIN="$OLD_APP/Contents/MacOS/CodexLimitAura"
OLD_AGENT="$AGENT_DIR/com.codex-pet.limit-aura.plist"
GUI_TARGET="gui/$(id -u)"

mkdir -p "$(dirname "$APP")" "$AGENT_DIR" "$HOME/Library/Logs"

launchctl bootout "$GUI_TARGET" "$AGENT" >/dev/null 2>&1 || true
launchctl bootout "$GUI_TARGET" "$OLD_AGENT" >/dev/null 2>&1 || true
pkill -TERM -f "$BIN" >/dev/null 2>&1 || true
pkill -TERM -f "$OLD_BIN" >/dev/null 2>&1 || true
pkill -TERM -f "CodexPetLimitRings.app/Contents/MacOS/CodexPetLimitRings" >/dev/null 2>&1 || true
pkill -TERM -f "CodexLimitAura.app/Contents/MacOS/CodexLimitAura" >/dev/null 2>&1 || true
rm -f "$OLD_AGENT"
rm -rf "$OLD_APP"

"$ROOT/tools/build-limit-rings.sh" "$APP" >/dev/null

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.codex-pet.limit-rings</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>LimitLoadToSessionType</key>
  <string>Aqua</string>
  <key>StandardOutPath</key>
  <string>$HOME/Library/Logs/CodexPetLimitRings.log</string>
  <key>StandardErrorPath</key>
  <string>$HOME/Library/Logs/CodexPetLimitRings.err.log</string>
</dict>
</plist>
PLIST

launchctl enable "$GUI_TARGET/com.codex-pet.limit-rings"
launchctl bootstrap "$GUI_TARGET" "$AGENT"
launchctl kickstart -k "$GUI_TARGET/com.codex-pet.limit-rings"

echo "Codex Pet Limit Rings installed at $APP"
echo "Menu bar item: Codex Pet Limit Rings icon"
