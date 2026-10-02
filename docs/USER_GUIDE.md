# BreakGuard User Guide

BreakGuard runs in the macOS menu bar. It counts focus time, warns before a break, and shows a break countdown on every connected display. Settings and statistics stay on your Mac.

## First Launch

Use the setup commands in the [README](../README.md#quick-start). After launch, open the eye-and-timer menu and choose **Settings**.

Default timing is thirty minutes of focus and a two-minute break, with a one-minute warning. Camera call detection is on; microphone detection, Harder mode, working hours, and the scheduled break are off. Launch at Login is on by default and may need macOS approval. Notification permission is optional: the timer and break overlay work without it.

## Breaks and the Menu

The menu-bar countdown turns red during the warning window. A yellow badge marks postponed or extended focus, time outside working hours, and an engaged call hold. Red warning takes priority, except during a call hold.

**Take a Break Now** starts an early break. Its **Cancel Break** button restores the remaining focus time without counting time on the overlay as work. Once the focus deadline has passed, the required break uses the normal skip rules instead.

A required break offers two configured postponement durations. Hold a button for the time shown beside it to confirm. The default holds are two and six seconds; repeat postponements in the same cycle take four and twelve seconds. Harder mode uses four and twelve seconds from the first postponement. Postponing records a violated cycle and resets the clean streak. Time already spent resting before the skip does not become focus time.

When the countdown reaches zero, the completion screen counts total rest time upward. Press **Continue Working** to record the break and start the next focus cycle. A completed break cannot be postponed or skipped by a hold that finishes late.

**Extend Focus** offers fifteen, thirty-five, forty-five, or sixty-five extra minutes before a break is due. The menu shows the resulting end time. The confirmation waits six seconds for the shortest option and fifteen seconds for the others; Harder mode doubles those waits. Extensions count as focus and spend a regular skip use, but do not record a violation.

**Pause Until 9 AM** silences reminders until the next local 9:00 AM, including across sleep and relaunch. Its confirmation waits ninety seconds, or three minutes in Harder mode. When the end time arrives, a fresh cycle starts. **Resume Now** ends the pause early and restores the saved remaining countdown; an early resume does not award a break just because the pause was long.

**Quit** has the same confirmation wait as pausing until morning. Cancel remains available during confirmation waits. If a break falls due during a dialog, the break takes priority.

## Harder Mode and the Daily Budget

Enable **Harder to skip breaks** on General to apply both limits:

- One regular skip per focus cycle: either Extend Focus or a postponement.
- A shared daily budget, defaulting to three uses and configurable from zero to ten.

General shows **Skips left today**. The menu and required-break screen also show the allowance. At zero, regular skips are disabled; manual-break cancellation remains available. Local midnight restores the daily allowance but does not restore a skip already used in the current cycle.

Usage survives new cycles, restarts, and resetting statistics. Normal mode allows repeated skips, but those uses count if you enable Harder mode later that day. Cancelled or rejected actions spend nothing. Increasing the budget while Harder mode is active is treated as loosening settings.

A required break also has an **Emergency override** disclosure. Hold its button for three seconds to trade the break for ninety minutes of focus. It works independently of the daily budget, once every rolling seven days, and records a violation. Manual breaks offer Cancel Break instead. General shows when the override is available again.

Turning Harder mode off requires a ninety-second confirmation. Turning it on is immediate.

## Calls and Screen Sharing

General has two separate options:

- **Hold breaks during camera calls**, enabled by default.
- **Hold breaks while microphone is in use**, disabled by default and available on macOS 14.2 or later.

While a selected device is active, a running countdown stops shrinking near the warning window. The held time still counts as focus. After device activity ends, at least two minutes remain before the break, or the effective warning lead if it is longer. If both devices are active, ending one does not release the other. Starting device activity does not dismiss a break already on screen.

Microphone detection reads activity only and records no sound. Music playback alone does not trigger it. Recording or dictation can trigger it; a muted call is detected only if its app keeps audio input active. Camera use outside a call can also trigger the camera hold. The menu names the camera, microphone, or both as the hold reason. Activity is checked each second, and missing devices or failed reads do not retain an earlier active flag.

There is no separate automatic screen-sharing detector. A shared-screen call is covered while a selected camera or microphone is in use. Sharing a screen without either active device does not hold breaks.

## Schedule Reminders

Schedule contains optional working hours and a daily scheduled break. Working hours use separate weekday and weekend ranges. A disabled day category has no outside-hours reminder. Ranges stay within one day. The scheduled break runs on weekdays only and defaults to 15:30–16:00.

With Harder mode off, working hours only change the menu-bar color. With Harder mode on, working outside the selected hours or during the scheduled break shows a reminder card. The scheduled-break reminder takes priority when both apply.

The card does not dim the screen. It stays fixed in place and keeps returning above other app windows, including when you switch apps or Spaces. Hold **Dismiss for 1m 30s** for three seconds to hide it; it returns ninety seconds later while the same pressure remains. You can also start a break. A new reminder episode starts with the card visible.

Cards stay hidden during calls selected in General, pauses, real breaks, and the emergency override's ninety-minute grant. Completing a break inside the scheduled window satisfies that window. A short break does not remove outside-hours reminders for the rest of the day.

The card's **Emergency override** disclosure contains **Pause Reminders**, which spends the same weekly override as the break screen. From the card it only buys ninety minutes of quiet: it leaves the countdown running and records no violation or daily skip use.

## Settings and Statistics

Settings has five tabs: General, Schedule, System, Statistics, and About.

**General** controls timing, focus pace, skip limits, calls, and advanced durations. Fields accept `minutes:seconds`; a plain number means minutes. A warning lead of zero disables warnings. The effective lead never exceeds half the focus window.

More Breaks uses 80% of the configured focus interval; Deep Focus uses 120%. Tapering gradually shortens future windows as actual focus accumulates, with a maximum twelve-minute reduction. It resets after the configured focus-free gap, or after at least three hours away that cross into a new local day. General shows the current reduction and reset status.

**System** controls notification sound, notification testing, Launch at Login, and menu-bar seconds. **Statistics** shows streaks, completed breaks, focused minutes, and recent daily comparisons. Detailed daily history covers 28 days; the lifetime focus total is retained. Reset Statistics does not refill skip quotas. **About** shows application information.

Settings apply and save immediately. When you close Settings, a net loosening while Harder mode was active at either end of the visit requires one five-minute confirmation. Examples include a larger skip budget, longer focus window, shorter break, enabling call holds, or reducing schedule pressure. Cancel restores the visit except the Harder-mode toggle, which has its own confirmation. If a break interrupts the question, it returns after the break. There is no Restore Defaults button.

## Sleep, Lock, and Inactivity

While a break countdown or completion screen is visible, BreakGuard prevents automatic idle display and system sleep. This keeps the clock visible. Explicit sleep, lid closure, and screen lock still work.

Sleep, lock, and screen saver count as rest. They start a break from a running countdown, and an existing break keeps its wall-clock deadline. Returning normally shows the remaining rest time or its completion screen. A long absence satisfying the tapering reset rule can complete the old cycle automatically. Sleep is never credited as focus.

Ten minutes without input pauses a running countdown instead of proving a completed break. Input returning restores the remaining time and excludes the idle period from focus. Active camera use and selected microphone use prevent calls from being mistaken for input idle. Fully passive reading or viewing with no input can still pause the timer.

Relaunch restores saved deadlines and uses heartbeat gaps to account for time the app could not monitor. A quick quit and relaunch can carry on the same cycle. It does not always grant a new focus window.

## Notifications, Data, and Limits

BreakGuard asks for notification permission on first launch. System settings show permission, alert style, and delivery capability. The preview reports whether a request was queued and whether delivery was observed. macOS notification settings and Focus modes can affect presentation.

The default ad-hoc signed bundle uses regular active notifications. Time Sensitive delivery needs an eligible Apple signing profile, the matching entitlement, and user permission.

State is stored at:

```text
~/Library/Application Support/BreakGuard/state.json
```

Missing optional fields in a compatible schema-3 file use defaults. Other schemas or invalid files start from defaults. Logs are available in Console using `subsystem:local.bohdan.BreakGuard`, or from Terminal:

```bash
log stream --predicate 'subsystem == "local.bohdan.BreakGuard"' --style compact
```

The overlay uses normal macOS app APIs. Force Quit, system navigation, logout, and window-management behavior remain controlled by macOS. Screen-sharing-only activity, real device changes, multiple displays, and hardware sleep should be checked on the target Mac after installation.
