# BreakGuard Architecture

## State Machine

`StateMachine` owns the timer lifecycle:

```text
working -> warning -> breakDue -> breaking -> breakCompleted -> working
breakDue/breaking/breakCompleted -> postponed -> breakDue
working/warning/postponed -> suspended -> previous state or a fresh cycle (sleep/inactivity, or user pause until 9 AM)
```

The UI calls explicit methods such as `takeBreakNow`, `cancelManualBreak`, `extendFocus(by:)`, `markBreakTaken`, `postpone`, `startBreak`, and `completeBreak(classification:)`. A completed break must be classified with a configured focus-tag ID, the explicit skipped outcome, or `.untracked` (used when focus tags are disabled in settings: the break and streak count, but no focus minutes are credited anywhere). Streaks, focus-category totals, skipped totals, and violation counters are updated only by the state machine.

`takeBreakNow` distinguishes manual breaks from scheduled ones by capturing a `ManualBreakOrigin` snapshot (interrupted phase, remaining time to the deadline, capture timestamp) in the runtime state; scheduled breaks reached through `tick` never set it. While the origin exists, the overlay offers only `cancelManualBreak`, which rebuilds the interrupted state with the remaining time re-anchored to the current moment (landing directly in `warning` when the remaining time is inside the warning lead), shifts the cycle start forward so overlay time is not credited as focus, and records nothing.

`extendFocus(by:)` shifts the current work (or postponed) deadline forward before the break is due. It is planned-ahead honesty rather than a postponement: no violation is recorded and no statistics change, while the extended time later counts toward focus minutes.

The `suspended` state is entered two ways: automatically by sleep/inactivity preservation (`suspend(until: nil)`), and by the user-facing **Pause Until 9 AM** menu action, which calls `suspend(until:)` with the next 9:00 AM. A timed pause outlives sleep and relaunch: `restoreAfterSleep()` leaves it untouched while its end date is in the future and starts a fresh cycle once that date has passed. While a pause of either kind is active, the menu offers **Resume Now**.

## Timer and Deadline Model

BreakGuard stores absolute deadlines for work, warning, break, postpone, and suspension timing. UI timers only refresh display text and call `tick`; they do not decrement authoritative counters. Tests use a fake clock to validate transitions without real waiting.

## Persistence

`PersistenceStore` writes one JSON file atomically under:

```text
~/Library/Application Support/BreakGuard/state.json
```

The persisted data includes a schema version, settings, the ordered focus-tag catalog, statistics, current state, cycle violation status, current-cycle postponement count, cycle start date, the captured focus duration of the current cycle, preserved sleep/suspension timing, the break start timestamp (drives the completion-screen rest count-up), and the manual-break origin snapshot. Statistics credit focus time in minutes of actual focused work per cycle (postponed time counts, paused/sleep time does not). Schema-2 files are migrated in place with the minute-based focus counters starting from zero; files with any other non-current schema version are discarded and replaced with defaults.

Later additions stay on schema 3 by being decode-lenient: the new runtime fields are optionals, and `AppSettings` (like `Statistics`) uses a lenient `init(from:)` so fields absent from older files fall back to their defaults instead of failing the load. `TimerState` cases deliberately keep their persisted payload shape; per-break metadata belongs in `RuntimeState`, not in new associated values.

## Overlay Window Management

`OverlayScreenManager` creates one borderless `NSPanel` per `NSScreen`, keeps the windows above normal application windows, joins Spaces, participates as a full-screen auxiliary window where macOS permits, and updates when displays change. Duplicate overlay windows are avoided by tracking screen identifiers.

The overlay view has two modes. During the break it shows the countdown plus the postpone buttons for scheduled breaks, or a single Cancel Break button for manually started ones (postponing a break the user just chose makes no sense). After the countdown reaches zero it switches to the completion screen, where a green clock counts total rest time upward (now minus break start, refreshed by the same one-second publish cycle as the countdown) and the user classifies the cycle with a focus tag, Skip, or — when focus tags are disabled — a single Continue Working button.

The overlay is a best-effort blocking interface. macOS still allows Force Quit, process termination, and system-level navigation.

## Sleep and Wake Handling

`SleepWakeManager` listens for workspace sleep/wake and session active/inactive notifications. Before sleep or inactivity, BreakGuard preserves remaining time and cancels warnings. After wake or reactivation, it resumes from the preserved duration so sleep time is not counted as work or break time.

Restoration applies a long-pause rule: if the preserved timestamp is at least one break duration in the past, the user certainly rested, so a fresh full work cycle starts instead (nothing is recorded — the same semantics as "Just Took a Break"). This covers sleep, clean quit/relaunch (`stop()` preserves before saving, and the persistence-restoring initializer calls the same restoration path), and pending-break states. As a crash-recovery fallback, a restored working/warning/postponed state without a preserved timestamp whose absolute deadline is already at least one break duration stale also starts a fresh cycle. Shorter pauses resume exactly where they left off. `resume()` itself applies the long-pause rule, so ending any pause — the tick reaching a timed pause's end date, or the user pressing Resume Now — starts a fresh cycle when the pause lasted at least one break duration and otherwise restores the preserved countdown.

## AppKit and SwiftUI Boundary

AppKit owns the menu bar item and its standard `NSMenu`, windows, activation policy, screen behavior, and lifecycle. SwiftUI renders the break overlay and the tabbed settings window. The completion overlay lays focus tags out in a fixed-column grid with uniform full-width buttons so the editable focus-tag catalog can grow without changing the state flow. Menu titles and available actions are derived from a testable presentation model shared with the AppKit controller.

## Notifications

`NotificationManager` owns both scheduled warning notifications and the Settings preview. A small notification-center client adapter makes system settings and scheduling behavior testable. The manager checks authorization, alert style, sound, and time-sensitive capability separately. The preview uses the same title, body, and sound preference as the real warning, but always uses regular active delivery; it reports queued, foreground-delivered, or unobserved delivery states through the notification-center delegate and a delivered-notification check.

Warning content is marked `.timeSensitive` only when `UNNotificationSettings.timeSensitiveSetting` is enabled; otherwise it is explicitly `.active`. Authorization requests include alert and sound only because the former time-sensitive authorization option is deprecated in favor of the entitlement. The matching entitlement is restricted — launchd refuses to spawn an ad-hoc signed bundle that carries it — so `build.sh` deliberately signs without it. Re-signing with an eligible provisioning profile enables true time-sensitive delivery without code changes, subject to the user's notification settings.
