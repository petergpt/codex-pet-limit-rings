#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${CODEX_PET_LIMIT_RINGS_APP:-$HOME/Applications/CodexPetLimitRings.app}"
BIN="$APP/Contents/MacOS/CodexPetLimitRings"
AGENT="$HOME/Library/LaunchAgents/com.codex-pet.limit-rings.plist"
OLD_APP="${CODEX_LIMIT_AURA_APP:-$HOME/Applications/CodexLimitAura.app}"
OLD_BIN="$OLD_APP/Contents/MacOS/CodexLimitAura"
OLD_AGENT="$HOME/Library/LaunchAgents/com.codex-pet.limit-aura.plist"
GUI_TARGET="gui/$(id -u)"

mkdir -p "$(dirname "$APP")"

launchctl bootout "$GUI_TARGET" "$AGENT" >/dev/null 2>&1 || true
launchctl bootout "$GUI_TARGET" "$OLD_AGENT" >/dev/null 2>&1 || true
pkill -TERM -f "$BIN" >/dev/null 2>&1 || true
pkill -TERM -f "$OLD_BIN" >/dev/null 2>&1 || true
pkill -TERM -f "CodexPetLimitRings.app/Contents/MacOS/CodexPetLimitRings" >/dev/null 2>&1 || true
pkill -TERM -f "CodexLimitAura.app/Contents/MacOS/CodexLimitAura" >/dev/null 2>&1 || true
rm -f "$AGENT" "$OLD_AGENT"
rm -rf "$APP" "$OLD_APP"

"$ROOT/tools/build-limit-rings.sh" "$APP" >/dev/null
open -n "$APP"

echo "Codex Pet Limit Rings installed for manual launch at $APP"
echo "LaunchAgent removed; it will not auto-start at login."
