#!/usr/bin/env bash
set -euo pipefail

if pgrep -x BreakGuard >/dev/null 2>&1; then
  osascript -e 'tell application "BreakGuard" to quit' >/dev/null 2>&1 || true
  sleep 1
fi

if pgrep -x BreakGuard >/dev/null 2>&1; then
  pkill -TERM -x BreakGuard || true
  sleep 1
fi

if pgrep -x BreakGuard >/dev/null 2>&1; then
  echo "BreakGuard is still running."
  exit 1
fi

echo "BreakGuard is stopped."
