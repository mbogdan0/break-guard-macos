#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BreakGuard"
SOURCE_APP="$ROOT/build/$APP_NAME.app"
TARGET_DIR="$HOME/Applications"
TARGET_APP="$TARGET_DIR/$APP_NAME.app"

"$ROOT/scripts/build.sh"
"$ROOT/scripts/stop.sh" || true

mkdir -p "$TARGET_DIR"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
codesign --verify --deep --strict --verbose=2 "$TARGET_APP"
open "$TARGET_APP"
sleep 2

if ! pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  echo "$APP_NAME did not remain running."
  exit 1
fi

echo "$TARGET_APP"
