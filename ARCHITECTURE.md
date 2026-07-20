# BreakGuard Architecture

## State Machine

`StateMachine` owns the timer lifecycle:

```text
working -> warning -> breakDue -> breaking -> breakCompleted -> working
breakDue/breaking/breakCompleted -> postponed -> breakDue
working/warning/postponed -> suspended -> previous state or a fresh cycle (sleep/inactivity, or user pause until 9 AM)
```

The UI calls explicit methods such as `takeBreakNow`, `cancelManualBreak`, `extendFocus(by:)`, `postpone`, `useEmergencyOverride()`, `startBreak`, and `completeBreak()`. `markBreakTaken` is still part of the machine and still tested, but nothing calls it right now: its "Just Took a Break" menu entry is commented out in `MenuBarController` while the feature is parked. Every completed break credits the actual focused minutes of its cycle to the daily focus totals. Streaks, daily focus totals, and violation counters are updated only by the state machine.

`takeBreakNow` distinguishes manual breaks from scheduled ones by capturing a `ManualBreakOrigin` snapshot (interrupted phase, remaining time to the deadline, capture timestamp) in the runtime state; scheduled breaks reached through `tick` never set it. While the origin exists, the overlay offers only `cancelManualBreak`, which rebuilds the interrupted state with the remaining time re-anchored to the current moment (landing directly in `warning` when the remaining time is inside the warning lead), shifts the cycle start forward so overlay time is not credited as focus, and records nothing.

`extendFocus(by:)` shifts the current work (or postponed) deadline forward before the break is due. It is planned-ahead honesty rather than a postponement: no violation is recorded and no statistics change, while the extended time later counts toward focus minutes. It sets `runtime.focusExtended`, which keeps the menu bar in its caution color until a new cycle clears the flag. With the `harderToSkipBreaks` setting on, the state machine allows one extension per cycle (`canExtendFocus`) and, once the cycle's first skip action — an extension or a postponement — is spent, reports `postponePenalized`, which doubles the hold the overlay's postpone buttons require.

`useEmergencyOverride()` is the escape hatch from that pressure: on a scheduled break it swaps the break for a `.postponed` window of `EmergencyOverride.focusGrant`, ignoring both gates above. It is not free — it records a violated cycle and resets the clean streak like a postponement, and it spends the cycle's extension and skip allowance so the grant cannot be stacked with a further extension. `canUseEmergencyOverride` requires a scheduled break (a manual one already has the free `cancelManualBreak` exit) and an elapsed cooldown; `emergencyOverrideAvailableAt` is `runtime.emergencyOverrideUsedAt` plus `EmergencyOverride.cooldown`, a rolling seven days rather than a calendar week so it cannot be spent twice across a weekend. The timestamp lives in `RuntimeState` precisely because "Restore Defaults" and "Reset Statistics" replace `AppSettings` and `Statistics` wholesale, either of which would refill the quota; `startWorkCycle()` therefore carries it explicitly through its rebuild of the runtime.

The Tapering focus pace shortens each window as the day accumulates. It measures focus actually put in rather than cycles completed: a cycle counter rewards anyone who takes several short manual breaks in a row, since each one closes a cycle. `runtime.taperedFocusSeconds` accumulates the focus of every cycle as it closes, and one accumulated focus minute costs one second off the next window — linear, with a non-configurable `FocusPace.taperingMinimumInterval` as a safety stop, since the rule has no asymptote of its own. A gap of `settings.taperingResetGap` without focus means the workday ended and the accumulator returns to zero.

Both the accumulator and the statistics credit derive from a single private `closedCycleFocus()`, which reports where the closing cycle's focus ended and how long it ran. Sharing it is not incidental: `postpone()` clears neither `cycleFocusDuration` nor `breakStartedAt`, so after a break is postponed and the user keeps working, those fields are stale. Reading them directly would charge tapering the pre-postponement figure while statistics credited the true one, and the two would drift apart silently. The helper's break branch trusts the duration captured at `startBreak()`; its countdown branch must not, and measures from the cycle start instead.

The `suspended` state is entered two ways: automatically by sleep/inactivity preservation (`suspend(until: nil)`), and by the user-facing **Pause Until 9 AM** menu action, which calls `suspend(until:)` with the next 9:00 AM. A timed pause outlives sleep and relaunch: `restoreAfterSleep()` leaves it untouched while its end date is in the future and starts a fresh cycle once that date has passed. While a pause of either kind is active, the menu offers **Resume Now**.

## Timer and Deadline Model

A new cycle's warning deadline goes through `AppSettings.effectiveWarningLeadTime(for:)`, which caps the configured lead at half the interval the cycle actually runs. `clamp()` can only bound the setting against the raw work interval, but the real interval may be shorter — scaled by the focus pace, or trimmed by tapering — and a lead reaching the whole window would open every cycle already in `warning`.

BreakGuard stores absolute deadlines for work, warning, break, postpone, and suspension timing. UI timers only refresh display text and call `tick`; they do not decrement authoritative counters. Tests use a fake clock to validate transitions without real waiting.

## Persistence

`PersistenceStore` writes one JSON file atomically under:

```text
~/Library/Application Support/BreakGuard/state.json
```

The persisted data includes a schema version, settings, statistics, current state, cycle violation status, current-cycle postponement count, the focus-extended flag, cycle start date, the captured focus duration of the current cycle, preserved sleep/suspension timing, the break start timestamp (drives the completion-screen rest count-up), the manual-break origin snapshot, the tapering focus accumulator, and the last use of the emergency override. Statistics credit focus time in minutes of actual focused work per cycle (postponed time counts, paused/sleep time does not) into daily totals keyed by local-calendar day. Files with a non-current schema version are discarded and replaced with defaults.

Later additions stay on schema 3 by being decode-lenient: `AppSettings` and `RuntimeState` use a lenient `init(from:)` so fields absent from older files (the working-hours settings, `focusExtended`) fall back to their defaults instead of failing the load, and JSON keys from removed features (the former focus-tag catalog and per-tag counters) are silently ignored. `TimerState` cases deliberately keep their persisted payload shape; per-break metadata belongs in `RuntimeState`, not in new associated values.

## Overlay Window Management

`OverlayScreenManager` creates one borderless `NSPanel` per `NSScreen`, keeps the windows above normal application windows, joins Spaces, participates as a full-screen auxiliary window where macOS permits, and updates when displays change. Duplicate overlay windows are avoided by tracking screen identifiers.

The overlay view has two modes. During the break it shows the countdown plus the postpone buttons for scheduled breaks, or a single Cancel Break button for manually started ones (postponing a break the user just chose makes no sense). After the countdown reaches zero it switches to the completion screen, where a green clock counts total rest time upward (now minus break start, refreshed by the same one-second publish cycle as the countdown) and a single Continue Working button completes the break.

The overlay is a best-effort blocking interface. macOS still allows Force Quit, process termination, and system-level navigation.

## Sleep and Wake Handling

`SleepWakeManager` listens for workspace sleep/wake and session active/inactive notifications. Before sleep or inactivity, BreakGuard preserves remaining time and cancels warnings. After wake or reactivation, it resumes from the preserved duration so sleep time is not counted as work or break time.

Restoration applies a long-pause rule: if the preserved timestamp is at least one break duration in the past, the user certainly rested, so a fresh full work cycle starts instead (nothing is recorded, on the honor-system reading that time away from the screen was rest). This covers sleep, clean quit/relaunch (`stop()` preserves before saving, and the persistence-restoring initializer calls the same restoration path), and pending-break states. As a crash-recovery fallback, a restored working/warning/postponed state without a preserved timestamp whose absolute deadline is already at least one break duration stale also starts a fresh cycle. Shorter pauses resume exactly where they left off. `resume()` itself applies the long-pause rule, so ending any pause — the tick reaching a timed pause's end date, or the user pressing Resume Now — starts a fresh cycle when the pause lasted at least one break duration and otherwise restores the preserved countdown.

## AppKit and SwiftUI Boundary

AppKit owns the menu bar item and its standard `NSMenu`, windows, activation policy, screen behavior, and lifecycle. SwiftUI renders the break overlay and the tabbed settings window. Menu titles, available actions, and the menu bar emphasis (`none`/`caution`/`urgent`) are derived from a testable presentation model shared with the AppKit controller. `caution` (a muted amber pill) marks borrowed time — a postponed break, an extended focus window, or time outside the configured working hours; `urgent` (the red pill) marks the warning lead window and always wins over caution. Both pills are pre-rendered non-template bitmaps because the menu bar's template/vibrancy pipeline flattens explicit text colors.

## Notifications

`NotificationManager` owns both scheduled warning notifications and the Settings preview. A small notification-center client adapter makes system settings and scheduling behavior testable. The manager checks authorization, alert style, sound, and time-sensitive capability separately. The preview uses the same title, body, and sound preference as the real warning, but always uses regular active delivery; it reports queued, foreground-delivered, or unobserved delivery states through the notification-center delegate and a delivered-notification check.

Warning content is marked `.timeSensitive` only when `UNNotificationSettings.timeSensitiveSetting` is enabled; otherwise it is explicitly `.active`. Authorization requests include alert and sound only because the former time-sensitive authorization option is deprecated in favor of the entitlement. The matching entitlement is restricted — launchd refuses to spawn an ad-hoc signed bundle that carries it — so `build.sh` deliberately signs without it. Re-signing with an eligible provisioning profile enables true time-sensitive delivery without code changes, subject to the user's notification settings.
