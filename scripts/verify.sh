#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/BreakGuard.app"
INSTALLED="$HOME/Applications/BreakGuard.app"

cd "$ROOT"
swift test
"$ROOT/scripts/build.sh" >/dev/null
test -d "$APP"
plutil -lint "$APP/Contents/Info.plist"
test -x "$APP/Contents/MacOS/BreakGuard"
codesign --verify --deep --strict --verbose=2 "$APP"

"$ROOT/scripts/stop.sh" >/dev/null 2>&1 || true
mkdir -p "$HOME/Applications"
rm -rf "$INSTALLED"
ditto "$APP" "$INSTALLED"
open "$INSTALLED"
sleep 2
if ! pgrep -x BreakGuard >/dev/null 2>&1; then
  echo "Application did not remain alive."
  exit 1
fi

echo "Verification passed."
