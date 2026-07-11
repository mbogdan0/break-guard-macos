#!/usr/bin/env bash
# Remote quick-start installer, fetched with curl and piped to bash.
# All logic stays inside main(), which is called on the last line, so a
# truncated download executes nothing.
set -euo pipefail

main() {
  local repo_url="https://github.com/mbogdan0/break-guard-macos.git"
  local checkout="$HOME/BreakGuard"

  if ! xcode-select -p >/dev/null 2>&1; then
    echo "Apple Command Line Tools are required."
    echo "Approve the installation prompt, wait for it to finish, then run this command again."
    xcode-select --install || true
    exit 1
  fi

  if [ -d "$checkout/.git" ]; then
    echo "Updating existing checkout at $checkout"
    git -C "$checkout" pull --ff-only
  else
    git clone --depth 1 "$repo_url" "$checkout"
  fi

  "$checkout/scripts/setup.sh"
}

main "$@"
