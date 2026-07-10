#!/usr/bin/env bash
set -euo pipefail

version="$(sw_vers -productVersion)"
major="${version%%.*}"
if [[ "$major" -lt 13 ]]; then
  echo "macOS 13 or newer is required. Current version: $version"
  exit 1
fi

if ! xcode-select -p >/dev/null 2>&1; then
  echo "Apple Command Line Tools are required. Run: xcode-select --install"
  xcode-select --install || true
  exit 1
fi

swift --version
xcrun --sdk macosx --show-sdk-path >/dev/null
echo "Bootstrap checks passed."
