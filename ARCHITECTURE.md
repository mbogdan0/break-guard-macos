# BreakGuard Architecture

## State Machine

`StateMachine` owns the timer lifecycle:

```text
working -> warning -> breakDue -> breaking -> breakCompleted -> working
breakDue/breaking/breakCompleted -> postponed -> breakDue
working/warning/postponed -> suspended -> previous state
```

The UI calls explicit methods such as `takeBreakNow`, `postpone`, `suspend`, `resume`, `startBreak`, and `completeBreak(classification:)`. A completed break must be classified with a configured focus-tag ID or the explicit skipped outcome. Streaks, focus-category totals, skipped totals, and violation counters are updated only by the state machine.

## Timer and Deadline Model

BreakGuard stores absolute deadlines for work, warning, break, postpone, and suspension timing. UI timers only refresh display text and call `tick`; they do not decrement authoritative counters. Tests use a fake clock to validate transitions without real waiting.

## Persistence

`PersistenceStore` writes one JSON file atomically under:

```text
~/Library/Application Support/BreakGuard/state.json
```

The persisted data includes a schema version, settings, the ordered focus-tag catalog, statistics, current state, cycle violation status, current-cycle postponement count, cycle start date, and preserved sleep/suspension timing. Files without the current schema version are discarded and replaced with defaults; no compatibility migration is attempted.

## Overlay Window Management

`OverlayScreenManager` creates one borderless `NSPanel` per `NSScreen`, keeps the windows above normal application windows, joins Spaces, participates as a full-screen auxiliary window where macOS permits, and updates when displays change. Duplicate overlay windows are avoided by tracking screen identifiers.

The overlay is a best-effort blocking interface. macOS still allows Force Quit, process termination, and system-level navigation.

## Sleep and Wake Handling

`SleepWakeManager` listens for workspace sleep/wake and session active/inactive notifications. Before sleep or inactivity, BreakGuard preserves remaining time and cancels warnings. After wake or reactivation, it resumes from the preserved duration so sleep time is not counted as work or break time.

## AppKit and SwiftUI Boundary

AppKit owns the menu bar item and its standard `NSMenu`, windows, activation policy, screen behavior, and lifecycle. SwiftUI renders the break overlay and the tabbed settings window. The completion overlay uses an adaptive grid so the editable focus-tag catalog can grow without changing the state flow. Menu titles and available actions are derived from a testable presentation model shared with the AppKit controller.

## Notifications

`NotificationManager` owns both scheduled warning notifications and the Settings preview. The preview uses the same title, body, and sound preference as the real warning and is presented while the app is active through the notification-center delegate.
