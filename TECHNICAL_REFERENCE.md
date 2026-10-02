# BreakGuard Technical Reference

This reference describes the current source behavior and identifies the responsible code. For design boundaries, see [Architecture](ARCHITECTURE.md).

## Settings

Durations are stored in seconds. Fields accept `minutes:seconds`; a bare number means minutes. Invalid syntax and integer overflow are rejected before conversion. Settings are clamped before use.

| Setting | Default | Range or meaning |
| --- | --- | --- |
| Work interval | 30 min | 30 s–4 h before pace scaling |
| Break duration | 2 min | 30 s–1 h |
| Warning lead | 1 min | 0–30 min; zero disables warnings |
| First postponement | 2 min | 30 s–2 h |
| Second postponement | 15 min | 30 s–2 h |
| Focus pace | Normal | More Breaks, Normal, Deep Focus, Tapering |
| Tapering reset gap | 6 h | 1–24 h without focus |
| Harder to skip breaks | Off | Per-cycle and daily limits, stronger confirmation gates, schedule cards |
| Daily skip budget | 3 | 0–10; enforced only in Harder mode |
| Camera call hold | On | Any camera reported in use |
| Microphone hold | Off | Process input activity; macOS 14.2+ |
| Working hours | Off | Separate weekday/weekend ranges |
| Weekday range | Enabled, 09:00–18:00 | Applies only when working hours are on |
| Weekend range | Disabled, 09:00–18:00 | A disabled category applies no pressure |
| Scheduled break | Off, 15:30–16:00 | Weekdays only; card requires Harder mode |
| Notification sound | On | Subject to system permission |
| Launch at login | On | Subject to login-item approval |
| Menu-bar seconds | On | Optional coarse seconds are off |

Working-hours ranges use local minutes from midnight, require at least five minutes, and do not cross midnight. Membership includes the start and excludes the end. Weekday/weekend categories follow `Calendar.isDateInWeekend`.

Sources: `Domain/AppSettings.swift`, `Domain/WorkingHours.swift`, `Domain/Formatting.swift`.

## Pace and Warning Math

More Breaks multiplies the base window by 0.8; Deep Focus uses 1.2; Normal and Tapering use 1.0. Tapering subtracts 1.2 seconds per accumulated focus minute, capped at twelve minutes. Its minimum window is ten minutes unless the configured base is already shorter. The stored accumulator is sanitized and capped at 240 hours.

Tapering resets after the configured focus-free gap, or after a gap of at least three hours that crosses into a new local day. Midnight alone does not reset it. Recovery and cycle restart measure that gap from the last monitored focus, so repeated unattended wakeups do not restart the gap.

The effective warning lead is `min(configuredLead, effectiveWindow / 2)`. Resume and manual cancellation reconstruct the same lead. Call holds preserve at least `max(effectiveLead, 120 seconds)` before a break.

Sources: `Domain/AppSettings.swift`, `Domain/StateMachine.swift`.

## Actions and Limits

A regular skip is a successful focus extension or postponement. Harder mode allows one per cycle and requires a remaining daily use. Normal mode permits repeated skips, but counts them toward today's usage if Harder mode is enabled later. Cancelled dialogs, invalid actions, and manual-break cancellation spend nothing.

The daily budget uses the local calendar day rather than a rolling 24 hours. A backwards clock change does not refill it. New cycles, relaunches, and statistics resets retain usage. Changing the limit changes remaining allowance against existing usage. The weekly override has an independent rolling seven-day cooldown and grants ninety minutes.

| Action | Normal mode | Harder mode |
| --- | --- | --- |
| Extend by 15 min | 6 s confirmation wait | 12 s |
| Extend by 35, 45, or 65 min | 15 s | 30 s |
| Pause until next 9 AM | 90 s | 180 s |
| Quit | 90 s | 180 s |
| First regular postponement | 2 s or 6 s hold | 4 s or 12 s hold |
| Repeated regular postponement | 4 s or 12 s hold | Unavailable in the same cycle |
| Weekly override | 3 s hold | 3 s hold |
| Dismiss schedule card | Card unavailable | 3 s hold; returns after 60 s |
| Disable Harder mode | Not applicable | 90 s confirmation wait |
| Net settings loosening on close | No charge | 5 min confirmation wait |

The longer configured postponement gets the longer hold; equal durations both use the shorter hold. Both buttons share the daily budget. A regular postponement records a violation once per cycle, resets the clean streak, and increments the postponement count. An extension spends budget and sets the caution flag, but records no violation.

The emergency override on a forced break records a violation and spends the cycle's skip allowance, but does not consume the daily budget. The same override on a schedule card only silences pressure for ninety minutes; it leaves the countdown and statistics alone. Both entry points share one cooldown. Manual breaks offer cancellation instead of the override. Elapsed break deadlines reject skips even before the next tick updates the screen.

Sources: `Domain/DailySkipUsage.swift`, `Domain/StateMachine.swift`, `Overlay/HoldToConfirmButton.swift`, `Application/HonestConfirmation.swift`.

## Settings Guard

Settings apply live. On opening Settings, `AppState` captures a baseline. On close, if Harder mode was on at either end, a net loosening triggers one five-minute confirmation. Cancel restores the visit except the Harder-mode toggle, which has its own gate. A break aborts the dialog without treating the interruption as an answer; the settings question returns after the break.

Loosening includes a longer window, weaker pace, shorter break, larger postponements or daily budget, earlier tapering reset, enabling a call hold, disabling login launch, widening/removing active working hours, and shortening/removing the scheduled break. Inactive ranges, warning lead, notification sound, and menu appearance do not incur this charge. There is no Restore Defaults control.

Sources: `Domain/SettingsGuard.swift`, `Application/AppState.swift`.

## Calls and Schedule Pressure

`AppState.tick()` reads camera and selected microphone activity before idle detection and timer transitions. All IDs are enumerated again on each tick; no listener or separate timer can strand a cached active flag. Camera detection requires `DeviceIsAlive`, input-scope `Streams`, and `DeviceIsRunningSomewhere` from CoreMediaIO. The running flag is device-wide; it is evidence of device IO, not proof of a call.

Microphone detection reads CoreAudio's current process list and `IsRunningInput`. It then requires the process's input-scope device list, a live running device, and an active input stream. Aggregate devices are checked through `ActiveSubDeviceList`; subdevice proxies are resolved through their UID to current devices, and visited IDs prevent cycles. Playback taps without an active input subdevice do not qualify. List reads use the returned byte count and reject malformed or oversized results; flags require exactly four bytes. Failed reads and absent devices clear activity evidence on that tick. Microphone properties are read only when selected and supported. Recording and dictation can engage the hold; muted calls depend on whether the app keeps audio input active.

Camera and selected microphone holds combine with OR: ending one does not release the other. Hold flags are transient and never restored from disk. Sleep or inactivity clears them, and wake samples current devices. Held time counts as focus. Already imposed breaks remain in force. Ending device activity leaves the held runway and rearms its warning. There is no maximum call duration or app-name heuristic. The menu identifies camera, microphone, or both as the reason for a hold. Screen sharing without selected device activity is not detected.

The scheduled-break card takes priority over outside-hours pressure. Both require Harder mode. The single card is fixed in place, nonactivating, and has no full-screen dimming layer. It sits just above the screen-saver window level and restores its front position on application or Space changes, with a two-second periodic backstop. It stays clear of the app's modal confirmations. Its action buttons share one rounded shape and height. A dismissal lasts ninety seconds from completion of its three-second hold. Reason changes and suppression end that dismissal episode. Pressure is suppressed during breaks, suspensions, selected calls, and the ninety-minute emergency grant. A completed break inside the scheduled window suppresses that window's card; it does not satisfy outside-hours pressure.

Sources: `Services/CallActivityReader.swift`, `Services/CameraUsageReader.swift`, `Services/MicrophoneUsageReader.swift`, `Services/HardwarePropertyClient.swift`, `Domain/BreakPressure.swift`, `Overlay/NudgeWindowManager.swift`.

## Sleep, Idle, and Recovery

The UI timer runs each second in common and modal-panel modes. Its callback ticks synchronously on the main run loop so modal confirmations cannot defer ticks and create false downtime. An in-memory tick gap of at least ninety seconds begins downtime from the last observed tick. Persisted heartbeats are minute-coarse; recovery treats a gap of at least 150 seconds as unmonitored time. Missing heartbeat data is handled as a relaunch gap.

Sleep, inactive session, screen lock, and screen saver are tracked as separate reasons. Effects resume only when all reasons clear. System absence starts a wall-clock break from a running countdown. Existing breaks retain their deadline; timed pauses retain their end time. Short absence returns to the remaining break or completion screen. A verified absence satisfying the tapering reset rule can automatically close the cycle and credit the rest. An expired timed pause starts a new cycle through the same resolution on both tick and wake paths.

Ten minutes of input silence suspends a running countdown back to the last input. Input silence alone does not complete a break. Returning input or call presence restores remaining time and excludes idle time from focus. A recent call limits idle backdating so the end of a long call cannot turn the whole call into absence.

`DisplaySleepAssertion` holds `PreventUserIdleDisplaySleep` and `PreventUserIdleSystemSleep` while the break or completion screen is visible. Timeout is the configured break duration plus five minutes, with a minimum of sixty seconds. Renewal happens halfway through that timeout using system uptime. Successful replacements are created before releasing prior assertions; failure retries on the next tick. Hiding the overlay releases them. Manual sleep, lock, and lid closure remain available.

Sources: `Domain/SessionActivity.swift`, `Domain/StateMachine.swift`, `Application/AppState.swift`, `Services/SleepWakeManager.swift`, `Services/DisplaySleepAssertion.swift`.

## Statistics and Persistence

Completed breaks credit rounded actual focus minutes, capped at four hours per cycle. Manual cancellation, idle, downtime, and time resting before a skip are excluded. Clean completions advance the streak; a violated cycle keeps it at zero. Automatic cycle closure after verified absence credits focus to its closed date. Daily history retains 28 days; the lifetime total survives pruning. Weekly comparisons use other recorded days in the same weekday/weekend category and require at least two baseline days.

State lives at `~/Library/Application Support/BreakGuard/state.json`. Schema 3 includes settings, statistics, and runtime. New optional fields have defaults when absent from a schema-3 file. Removed unknown fields are ignored. Other schemas, invalid JSON, or invalid required fields cause a fresh default state. Dates use ISO-8601. Writes use atomic replacement and skip identical snapshots. There is no remote persistence.

Sources: `Domain/Statistics.swift`, `Domain/WeeklyFocusSummary.swift`, `Domain/PersistedAppData.swift`, `Persistence/PersistenceStore.swift`.

## Notifications and Packaging

The notification manager checks authorization, alert style, sound, and Time Sensitive capability. It uses generation tokens and ordered submission/cancellation so late callbacks cannot overwrite a newer warning. Changes to warning time, break deadline, or sound require a new request; disabling warnings cancels the request. The Settings preview reports queued, observed delivery, or no observed delivery.

The default app is ad-hoc signed without the restricted Time Sensitive entitlement. Regular active delivery works without a paid developer account. Time Sensitive delivery requires an eligible signed bundle and system permission. macOS still controls actual presentation.

`./scripts/build.sh` passes the selected SDK version and package deployment target to the linker and checks the resulting `LC_BUILD_VERSION` metadata. This prevents a toolchain update from switching macOS controls to an older appearance. It resolves SwiftPM's release binary path, copies source resources into `Contents/Resources`, writes the bundle metadata, and verifies the ad-hoc signature. It creates `build/BreakGuard.app` without installing or launching it. `install.sh` and `verify.sh` also modify the installed app and launch it.

## Validation

Run `swift test` after source changes and `./scripts/build.sh` to verify packaging. The tests use fake clocks and system-client adapters for timer races, skip usage, persistence, recovery, notifications, and assertion renewal.

Manual checks on a Mac:

- Dismiss a schedule card, verify a three-second hold and a ninety-second return, and switch its reason.
- Spend regular skips across cycles, restart the app, and check midnight rollover and a zero budget.
- End camera and microphone activity separately; verify runway, warning delivery, and muted-call limitations.
- Let a break finish, lock and unlock, and check overlapping sleep/lock/saver events.
- Verify that a visible break prevents automatic sleep and that explicit sleep still counts as rest.
- Change the display layout while a break is visible and check every connected screen.

Real device activity, macOS window behavior, and hardware sleep need manual verification; unit tests do not replace those checks.
