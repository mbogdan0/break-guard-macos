#!/usr/bin/env bash
set -euo pipefail

DELETE_DATA=0
if [[ "${1:-}" == "--delete-data" ]]; then
  DELETE_DATA=1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$ROOT/scripts/stop.sh" || true
rm -rf "$HOME/Applications/BreakGuard.app"

if [[ "$DELETE_DATA" -eq 1 ]]; then
  rm -rf "$HOME/Library/Application Support/BreakGuard"
  defaults delete local.bohdan.BreakGuard >/dev/null 2>&1 || true
fi

echo "BreakGuard uninstalled."
