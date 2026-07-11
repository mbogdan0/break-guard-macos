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
swift_version="$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\.[0-9]*\).*/\1/p' | head -n 1)"
if [[ -z "$swift_version" ]]; then
  echo "Unable to determine the Swift version. Update Apple Command Line Tools and retry."
  exit 1
fi
swift_major="${swift_version%%.*}"
swift_minor="${swift_version#*.}"
if (( swift_major < 5 || (swift_major == 5 && swift_minor < 9) )); then
  echo "Swift 5.9 or newer is required. Current version: $swift_version"
  echo "Update Apple Command Line Tools or install a current Xcode, then retry."
  exit 1
fi

xcrun --sdk macosx --show-sdk-path >/dev/null
echo "Bootstrap checks passed."
