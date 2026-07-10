# BreakGuard

BreakGuard is a local native macOS menu bar utility that reminds you to take required eye-rest breaks. It uses Swift, SwiftUI, AppKit, Swift Package Manager, local notifications, `SMAppService.mainApp`, and ad-hoc code signing.

## System Requirements

- macOS 13 or newer
- Apple Command Line Tools or Xcode command-line tools
- No paid Apple Developer account
- No notarization, Developer ID, network services, analytics, or private APIs

## Quick Start

Run the environment check once, then build, install, and launch the app:

```bash
./scripts/bootstrap.sh
./scripts/install.sh
```

The installed application is located at:

```text
~/Applications/BreakGuard.app
```

`install.sh` is also the recommended command after changing the source code. It performs a release build, stops the currently running copy, replaces the installed app, verifies its signature, launches it, and checks that it remains running. Compatible settings and statistics are preserved.

## Commands

All commands should be run from the project root.

### Check the Development Environment

```bash
./scripts/bootstrap.sh
```

Checks the macOS version, Apple Command Line Tools, Swift toolchain, and macOS SDK.

### Run Tests

```bash
swift test
```

Builds the debug configuration and runs all unit tests.

### Build the App Bundle

```bash
./scripts/build.sh
```

Creates and ad-hoc signs the release application bundle at:

```text
build/BreakGuard.app
```

This command does not install or launch the app.

For raw Swift Package Manager builds without app bundling:

```bash
swift build
swift build -c release
```

### Install or Restart After Code Changes

```bash
./scripts/install.sh
```

This is the complete build, reinstall, and restart command. It installs the app to `~/Applications/BreakGuard.app` and leaves it running.

### Start an Installed Copy

```bash
./scripts/run.sh
```

This only opens the existing app under `~/Applications`; run `./scripts/install.sh` first if it has not been installed.

### Stop the App

```bash
./scripts/stop.sh
```

Requests a normal quit and falls back to terminating the process if necessary.

### Run Full Verification

```bash
./scripts/verify.sh
```

Runs unit tests, creates a release app bundle, validates its `Info.plist` and executable, verifies the signature, replaces the installed copy, launches it, and checks for an immediate crash. The verified app remains running.

### Uninstall

Remove the application while preserving settings and statistics:

```bash
./scripts/uninstall.sh
```

Remove the application and all locally persisted BreakGuard data:

```bash
./scripts/uninstall.sh --delete-data
```

## Using BreakGuard

The menu bar displays an eye icon and the current timer. Clicking it opens a standard macOS menu with the current status, an immediate break action, pause durations, Settings, and Quit. While monitoring is paused, the action menu is replaced by Resume Now.

Settings contains two tabs:

- **General** configures timing, postponement durations, notification sound, launch at login, menu-bar seconds, focus tags, and system permissions. It can also send a test warning notification.
- **Statistics** displays all-time focus-category totals, skipped sessions, streaks, and break history, and provides the confirmed reset action.

Settings changes are saved immediately. Restore Defaults resets configuration but does not clear statistics.

After every completed break, the overlay asks which focus tag describes the preceding work interval. `Work` and `Study` are provided by default, and tags can be added, renamed, or deleted in General settings. Choosing `Skip` still records the completed break and streak result but does not credit a focus category.

## Notification Permission

On first launch, macOS may ask for notification permission. BreakGuard remains functional if notifications are disabled, but the configured advance-warning banner will not appear. When access is disabled, General settings provides a link to macOS Notification Settings.

## Launch at Login

BreakGuard uses `SMAppService.mainApp` for launch at login. macOS may require user approval in System Settings. General settings displays the actual system status and provides a System Settings link when approval is required.

## Logs

Inspect logs in Console.app by filtering for:

```text
subsystem:local.bohdan.BreakGuard
```

Or stream them from Terminal:

```bash
log stream --predicate 'subsystem == "local.bohdan.BreakGuard"' --style compact
```

Persisted state is stored at:

```text
~/Library/Application Support/BreakGuard/state.json
```

The persisted file is schema-versioned. Incompatible or unversioned data is intentionally reset rather than migrated.

## Manual System Actions

The only possible manual actions are:

1. Installing Apple Command Line Tools if absent.
2. Approving notification permission.
3. Approving the Login Item if macOS requests it.

## Known macOS Limitations

The overlay is a best-effort blocking interface. macOS still allows Force Quit, process termination, account logout, system-level navigation, and other actions outside a normal app's public API control. Full-screen and Stage Manager behavior depends on macOS window-management rules.
