#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BreakGuard"
BUNDLE_DIR="$ROOT/build/$APP_NAME.app"

cd "$ROOT"
MACOS_SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
MACOS_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_MACOS_VERSION="$(swift package dump-package | plutil -extract platforms.0.version raw -o - -)"
# Record the SDK used to build the UI, separately from the deployment target.
# An incorrect SDK stamp makes macOS use older control and window styles.
BUILD_OPTIONS=(
  -c release --sdk "$MACOS_SDK_PATH"
  -Xlinker -platform_version -Xlinker macos
  -Xlinker "$MIN_MACOS_VERSION" -Xlinker "$MACOS_SDK_VERSION"
)
swift build "${BUILD_OPTIONS[@]}"
BUILD_DIR="$(swift build "${BUILD_OPTIONS[@]}" --show-bin-path)"
if ! xcrun vtool -show-build "$BUILD_DIR/$APP_NAME" | awk -v sdk="$MACOS_SDK_VERSION" -v minimum="$MIN_MACOS_VERSION" '
  $1 == "sdk" { sdkCount++; if ($2 != sdk) invalid = 1 }
  $1 == "minos" { minimumCount++; if ($2 != minimum) invalid = 1 }
  END { exit (invalid || sdkCount == 0 || minimumCount == 0) }
'; then
  echo "Build metadata does not match the selected macOS SDK and deployment target." >&2
  exit 1
fi

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS" "$BUNDLE_DIR/Contents/Resources"
cp "$BUILD_DIR/$APP_NAME" "$BUNDLE_DIR/Contents/MacOS/$APP_NAME"
# The app reads these from Bundle.main. SwiftPM's resource-bundle layout
# depends on the build engine, so package the source resources directly.
cp -R "$ROOT/Sources/BreakGuard/Resources/." "$BUNDLE_DIR/Contents/Resources/"

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
  <string>5</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHumanReadableCopyright</key>
  <string>Copyright © 2026 Bohdan Melnichenko. Personal non-commercial license.</string>
</dict>
</plist>
PLIST

plutil -replace LSMinimumSystemVersion -string "$MIN_MACOS_VERSION" "$BUNDLE_DIR/Contents/Info.plist"
plutil -lint "$BUNDLE_DIR/Contents/Info.plist"

# Note: the com.apple.developer.usernotifications.time-sensitive entitlement
# cannot be included here — it is a restricted entitlement, and launchd
# refuses to spawn an ad-hoc signed bundle carrying it. The app checks the
# system capability and explicitly uses regular active delivery in this build.
codesign --force --deep --sign - "$BUNDLE_DIR"
codesign --verify --deep --strict --verbose=2 "$BUNDLE_DIR"
echo "$BUNDLE_DIR"
