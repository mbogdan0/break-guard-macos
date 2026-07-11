# BreakGuard

👁️ **BreakGuard is a small native macOS menu-bar app that makes sure you actually rest your eyes.** It counts down your focus time, warns you before a break, and shows a full-screen break overlay when it is time to look away.

Everything stays on your Mac: there are no accounts, servers, analytics, or network requests. BreakGuard also tracks completed breaks, clean streaks, and optional focus time by tags such as `Work` and `Study`.

## ⚡ Build and Run in Two Commands

You need:

- macOS 13 or newer
- Apple Command Line Tools or Xcode
- Git, if you are cloning the repository

No paid Apple Developer account is required.

From the project folder, run:

```bash
./scripts/bootstrap.sh
./scripts/install.sh
```

That is it. The first command checks your development environment. The second builds a release version, installs it, signs it locally, and launches it.

The app will appear in the menu bar as an eye with a timer. The installed application is located at:

```text
~/Applications/BreakGuard.app
```

💡 After changing the code, run `./scripts/install.sh` again. It safely stops the old copy, rebuilds and replaces it, then launches the new version. Compatible settings and statistics are preserved.

On first launch, macOS may ask for notification permission. Notifications are optional; the timer and break overlay work without them.

## 🧠 How It Works

1. Work while the menu-bar timer counts down.
2. Get an optional notification shortly before the break.
3. When time is up, BreakGuard covers your screens with a break countdown.
4. Finish the break, optionally tag the focus session, and start a fresh work cycle.

You can take a break early, tell the app about a break it did not observe, or extend focus before a meeting. Sleep and inactive time are handled automatically, so time away from your Mac is not counted as focused work.

## 🛠️ Commands

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

## 👁️ Using BreakGuard

The menu bar displays an eye icon and the current timer. Clicking it opens a standard macOS menu with the current status (the greyed-out first line shows the next break as a clock time, for example "Next break at 08:23"), an immediate break action, a "Just Took a Break" action, an "Extend Focus" submenu, Settings, and Quit. Action items carry monochrome system icons.

"Take a Break Now" starts the break immediately. Because you started it yourself, the break overlay offers an additional "Cancel Break" button that returns the timer to exactly where it was; the time spent on the overlay is not counted as focus time and nothing is recorded. A scheduled break has no cancel option — only the postpone buttons.

"Just Took a Break" is for rest the app could not observe — for example a real coffee break away from the desk. After a confirmation that asks you to be honest, it restarts the work timer as if a full break just ended. Nothing is recorded: no focus time, no streak changes.

"Extend Focus" pushes the current work deadline out by 15 minutes, 35 minutes, or 1 hour 5 minutes for times you know in advance the break will not fit (a meeting, a call). The 35-minute and 1-hour-5-minute options ask for confirmation first — an extension is rest you take away from yourself, and the dialog reminds you that taking the break is the healthier choice. Because the extension happens before the break is due, it is not a postponement: the clean streak is unaffected and no violation is recorded, while the extra time still counts toward focus minutes. There is no manual pause; monitoring is suspended automatically only around system sleep and inactivity.

When the break countdown reaches zero, the overlay switches to the completion screen and a green "Total rest time" clock starts counting up, so you can see how long you actually rested before returning to work.

Settings contains four tabs:

- **General** configures timing, postponement durations, and menu-bar seconds.
- **Focus Tags** toggles whether the app asks for a focus tag after each break, and manages the focus-tag catalog: adding, renaming, and deleting tags.
- **System** covers notification permission, notification sound, the test warning notification, and launch at login.
- **Statistics** displays all-time focus time per category (in minutes of actual focused work), skipped time, streaks, and break history, and provides the confirmed reset action.

Settings changes are saved immediately. Restore Defaults resets configuration but does not clear statistics.

After every completed break, the overlay asks which focus tag describes the preceding work interval. `Work` and `Study` are provided by default, and tags can be added, renamed, or deleted in Focus Tags settings. The chosen category is credited with the actual focused minutes of the cycle: postponed time counts toward focus, paused and sleep time does not, and an early break credits only the elapsed time. Choosing `Skip` still records the completed break, streak result, and skipped focus time, but does not credit a category.

If "Ask for a focus tag after each break" is turned off in Focus Tags settings, the completion screen shows a single "Continue Working" button instead. The break and streak still count, but no focus minutes are recorded anywhere — per-tag statistics are simply paused until the toggle is re-enabled.

## 😴 Sleep and Restart Behavior

A short interruption (closing the lid for less than your break duration) pauses the timer and resumes it with the same remaining time. A pause at least as long as the configured break duration — sleep, logout, quit, or a system restart — counts as a break you already took: BreakGuard starts a fresh full work cycle on wake or relaunch, recording nothing. With the default 2-minute break, any pause of 2 minutes or more starts a fresh session.

## 🔔 Notification Permission

On first launch, macOS may ask for notification permission. BreakGuard remains functional if notifications are disabled, but the configured advance-warning banner will not appear. When access is disabled, System settings provides a link to macOS Notification Settings.

## 🚀 Launch at Login

BreakGuard uses `SMAppService.mainApp` for launch at login. macOS may require user approval in System Settings. The System settings tab displays the actual system status and provides a System Settings link when approval is required.

## 🧾 Logs

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

The persisted file is schema-versioned. Schema 2 files are migrated in place (per-tag session counts were replaced by minute-based focus totals, which restart from zero); other incompatible or unversioned data is intentionally reset rather than migrated.

## 🧰 Manual System Actions

The only possible manual actions are:

1. Installing Apple Command Line Tools if absent.
2. Approving notification permission.
3. Approving the Login Item if macOS requests it.

## ⚠️ Known macOS Limitations

The overlay is a best-effort blocking interface. macOS still allows Force Quit, process termination, account logout, system-level navigation, and other actions outside a normal app's public API control. Full-screen and Stage Manager behavior depends on macOS window-management rules.
