#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BreakGuard"
BUILD_DIR="$ROOT/.build/release"
BUNDLE_DIR="$ROOT/build/$APP_NAME.app"

cd "$ROOT"
swift build -c release

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
if [[ -d "$BUILD_DIR/BreakGuard_BreakGuard.resources" ]]; then
  cp -R "$BUILD_DIR/BreakGuard_BreakGuard.resources/." "$BUNDLE_DIR/Contents/Resources/"
fi
if [[ -d "$BUILD_DIR/BreakGuard_BreakGuard.bundle" ]]; then
  cp "$BUILD_DIR/BreakGuard_BreakGuard.bundle/Resources/BreakGuard.icns" \
    "$BUNDLE_DIR/Contents/Resources/BreakGuard.icns"
fi

cat > "$BUNDLE_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>BreakGuard</string>
  <key>CFBundleIdentifier</key>
  <string>local.bohdan.BreakGuard</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>BreakGuard</string>
  <key>CFBundleIconFile</key>
  <string>BreakGuard</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.2</string>
  <key>CFBundleVersion</key>
  <string>3</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Bohdan Melnichenko. Personal non-commercial license.</string>
</dict>
</plist>
PLIST

plutil -lint "$BUNDLE_DIR/Contents/Info.plist"

# Note: the com.apple.developer.usernotifications.time-sensitive entitlement
# cannot be included here — it is a restricted entitlement, and launchd
# refuses to spawn an ad-hoc signed bundle carrying it. The app checks the
# system capability and explicitly uses regular active delivery in this build.
codesign --force --deep --sign - "$BUNDLE_DIR"
codesign --verify --deep --strict --verbose=2 "$BUNDLE_DIR"
echo "$BUNDLE_DIR"
