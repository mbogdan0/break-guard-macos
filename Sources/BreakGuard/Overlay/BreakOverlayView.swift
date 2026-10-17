import SwiftUI

enum BreakPromptCatalog {
    static let all = [
        "Stand up, step away from the screen, and give your eyes a rest.",
        "Look into the distance, relax your focus, and let your mind unwind.",
        "Move your body, breathe deeply, and reset your attention.",
        "Give your eyes a break and your brain a moment to recharge.",
        "Step away for a moment—your health matters more than the next task.",
        "Stretch, blink slowly, and release the tension from your eyes.",
        "Rest your vision, clear your mind, and return feeling refreshed.",
        "Protect your eyes: look away, move around, and take a real pause.",
        "Let your thoughts settle while your eyes recover from the screen.",
        "Stand, breathe, and enjoy a short break for your body and mind."
    ]

    static func random() -> String {
        all.randomElement()!
    }
}

struct BreakOverlayView: View {
    @ObservedObject var appState: AppState
    let breakPrompt: String

    var body: some View {
        ZStack {
            OverlayStyle.background
                .ignoresSafeArea()
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    Group {
                        if appState.isBreakCompleteAllowed() {
                            completionContent
                        } else {
                            breakContent
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: OverlayStyle.contentWidth)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 64)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
            wallClock
                .allowsHitTesting(false)
        }
    }

    // The overlay hides the menu bar, so this is the only clock the user has.
    // A ZStack sibling rather than part of either content stack: it shows on
    // both the break and completion screens without disturbing their layout.
    // Monospaced so the digits do not jitter the label's width every second.
    // TimelineView so only this Text re-evaluates each second: AppState no
    // longer republishes unchanged values, so the body cannot ride the tick.
    private var wallClock: some View {
        VStack {
            Spacer()
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(DateFormatter.breakGuardWallClock.string(from: context.date))
            }
            .font(.system(size: 17, design: .monospaced))
            .foregroundStyle(.white.opacity(0.33))
            .padding(.bottom, 30)
        }
        .ignoresSafeArea()
    }

    private var breakContent: some View {
        VStack(spacing: 0) {
            Text("Time for a break")
                .font(.system(size: 44, weight: .semibold))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(formatClock(appState.breakRemaining(at: context.date)))
            }
            // 8 monospaced digits do not fit the content width at this size,
            // and a break of a full hour opens on hh:mm:ss. Scale that one
            // case down rather than letting it truncate.
            .font(.system(size: 124, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.top, 12)
            if !appState.settings.encourageLongBreaks {
                Text(breakPrompt)
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
            }
            encouragement
            let actionSet = breakOverlayActionSet(
                isManualBreak: appState.isManualBreak,
                canPostpone: appState.canPostpone
            )
            if actionSet == .cancel {
                // The user chose this break; postponing it makes no sense.
                // The only exit besides finishing is cancelling it.
                Button {
                    appState.cancelManualBreak()
                } label: {
                    Text("Cancel Break")
                        .font(.system(size: 18, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.top, 48)
                Text("You started this break yourself — cancelling restores your remaining focus time.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            } else {
                let first = appState.settings.firstPostponeDuration
                let second = appState.settings.secondPostponeDuration
                if actionSet == .postpone {
                    HStack(spacing: 16) {
                        postponeButton(first, comparedTo: second)
                        postponeButton(second, comparedTo: first)
                    }
                    .padding(.top, 48)
                    if appState.settings.harderToSkipBreaks {
                        Text("\(appState.dailySkipsRemaining) of \(appState.settings.dailySkipLimit) skips left today")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 8)
                    }
                } else {
                    Text(appState.dailySkipsRemaining == 0
                         ? "Today's skip budget is used up. It resets at midnight."
                         : "A skip was already used this cycle. Complete this break to reset it.")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.top, 48)
                }
                emergencyOverrideSection
                    .padding(.top, 40)
            }
        }
    }

    // Deliberately understated: a dim, collapsed row that stays out of the way
    // until someone goes looking for it. Shown on a cooldown too — a hatch
    // nobody knows about is one nobody can plan around.
    private var emergencyOverrideSection: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    appState.emergencyDisclosureExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text("Emergency override")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(appState.emergencyDisclosureExpanded ? 90 : 0))
                }
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.35))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if appState.emergencyDisclosureExpanded {
                if appState.canUseEmergencyOverride {
                    HoldToConfirmButton(
                        title: "Skip Break · \(formatDurationCompact(EmergencyOverride.focusGrant))",
                        subtitle: postponeHoldHint(EmergencyOverride.holdDuration),
                        holdDuration: EmergencyOverride.holdDuration,
                        onPressingChanged: { appState.setOverlayHold($0, pressing: $1) }
                    ) {
                        appState.useEmergencyOverride()
                    }
                    .frame(width: 320)
                    .padding(.top, 14)
                    Text("Once every 6 days, whatever else is switched on. Use it when a break cannot wait.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)
                } else {
                    Text(emergencyUnavailableText)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.top, 12)
                }
            }
        }
    }

    private var emergencyUnavailableText: String {
        guard let availableAt = appState.emergencyOverrideAvailableAt else {
            return "Not available for this break."
        }
        // The wait, not the date it lands on: "in 3 days 5 hours" is the
        // question being asked, and a timestamp makes the reader do the
        // subtraction themselves.
        return "Available again in "
            + formatTimeUntilPhrase(availableAt.timeIntervalSinceNow) + "."
    }

    private var completionContent: some View {
        VStack(spacing: 0) {
            Text("Break completed")
                .font(.system(size: 44, weight: .semibold))

            // The break obligation is over; from here the clock counts UP.
            // Smaller and green so it reads as accrued rest, not a demand.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(formatClock(appState.totalRestTime(at: context.date)))
            }
            .font(.system(size: 48, weight: .semibold, design: .monospaced))
            .foregroundStyle(Color(nsColor: .systemGreen))
            .padding(.top, 10)
            Text("Total rest time")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.top, 4)

            encouragement
            continueWorkingContent
        }
    }

    @ViewBuilder private var encouragement: some View {
        if appState.settings.encourageLongBreaks {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                RestEncouragementView(status: appState.restEncouragement(at: context.date))
            }
            .padding(.top, 24)
        }
    }

    private var continueWorkingContent: some View {
        VStack(spacing: 0) {
            if !appState.settings.encourageLongBreaks {
                Text("Well rested. Ready when you are.")
                    .font(.system(size: 22))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 24)
            }
            Button {
                appState.completeBreak()
            } label: {
                Text("Continue Working")
                    .font(.system(size: 20, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding(.top, 32)
        }
    }

    private func postponeButton(_ duration: TimeInterval, comparedTo other: TimeInterval) -> some View {
        let hold = postponeHoldDuration(
            for: duration,
            comparedTo: other,
            tier: appState.postponeHoldTier
        )
        return HoldToConfirmButton(
            title: "Postpone for \(formatDurationCompact(duration))",
            subtitle: postponeHoldHint(hold),
            holdDuration: hold,
            onPressingChanged: { appState.setOverlayHold($0, pressing: $1) }
        ) {
            appState.postpone(seconds: duration)
        }
    }
}

enum BreakOverlayActionSet: Equatable {
    case cancel
    case postpone
    case unavailable
}

func breakOverlayActionSet(
    isManualBreak: Bool,
    canPostpone: Bool = true
) -> BreakOverlayActionSet {
    if isManualBreak { return .cancel }
    return canPostpone ? .postpone : .unavailable
}
