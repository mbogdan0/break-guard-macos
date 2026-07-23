import AppKit
import SwiftUI
import os

@MainActor
final class OverlayScreenManager {
    private weak var appState: AppState?
    private var windows: [String: BreakOverlayWindow] = [:]
    // The frame last handed to `setFrame`, per screen. Compared against instead
    // of the live `window.frame` because AppKit may hand back an adjusted rect;
    // if it ever does, comparing the live frame would never match and the
    // per-tick redraw this guard exists to prevent would quietly come back.
    private var appliedFrames: [String: NSRect] = [:]
    private var currentBreakPrompt: String?
    // Ticks until `bringToFront` re-asserts window order even though nothing
    // looks displaced. Starts at zero so the first call of every break always
    // reorders; `hideAll` resets it for the next one.
    private var reassertCountdown = 0
    // In ticks, and the tick is one second. Long enough that the cost is noise,
    // short enough that a window that stole the front is not there for long.
    private static let reassertInterval = 10
    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "Overlay")

    init(appState: AppState) {
        self.appState = appState
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateForScreenChanges),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    // Re-entered on every 1-second tick for as long as a break is on screen, so
    // each step here has to cost nothing when nothing changed. Re-framing with
    // `display: true` forces a synchronous redraw of a full-screen window, and
    // re-activating churns key-window state; once a second that is invisible on
    // a static overlay, but it drops frames under the hold-to-confirm fill.
    func showOnAllScreens() {
        guard let appState else { return }
        let prompt = currentBreakPrompt ?? BreakPromptCatalog.random()
        currentBreakPrompt = prompt
        for screen in NSScreen.screens {
            let key = screenKey(screen)
            if windows[key] == nil {
                let window = BreakOverlayWindow(screen: screen)
                window.contentView = NSHostingView(
                    rootView: BreakOverlayView(appState: appState, breakPrompt: prompt)
                )
                windows[key] = window
                logger.info("Overlay window created")
            }
            guard let window = windows[key] else { continue }
            if appliedFrames[key] != screen.frame {
                window.setFrame(screen.frame, display: true)
                appliedFrames[key] = screen.frame
            }
            if !window.isVisible {
                window.orderFrontRegardless()
            }
        }
        removeWindowsForDisconnectedScreens()
        makeOverlayKeyIfNeeded()
        activateIfNeeded()
    }

    @objc func updateForScreenChanges() {
        guard !windows.isEmpty else { return }
        showOnAllScreens()
    }

    // Also re-entered every second during a break. `orderFrontRegardless` draws
    // nothing, but it is a synchronous WindowServer round trip — on the main
    // thread, to the same process that is compositing this full-screen surface,
    // once per window per second. Invisible on a static overlay; it is what the
    // hold-to-confirm fill stutters against. So reorder only when the overlay
    // was actually displaced, and re-assert on a slow cadence to stay above
    // anything else that parks itself at `.screenSaver` without hiding us.
    func bringToFront() {
        reassertCountdown -= 1
        let reassert = reassertCountdown <= 0
        if reassert {
            reassertCountdown = Self.reassertInterval
        }
        for window in windows.values {
            var displaced = false
            if window.level != .screenSaver {
                window.level = .screenSaver
                displaced = true
            }
            if displaced || !window.isVisible || reassert {
                window.orderFrontRegardless()
            }
        }
        // `activateIfNeeded` is deliberately not called here: every caller
        // reaches this through `showOnAllScreens`, which already did it.
    }

    func hideAll() {
        if !windows.isEmpty {
            logger.info("Overlay dismissed")
        }
        for window in windows.values {
            window.orderOut(nil)
        }
        windows.removeAll()
        appliedFrames.removeAll()
        currentBreakPrompt = nil
        reassertCountdown = 0
    }

    // Keyboard input needs exactly one key window, and with several monitors
    // only one overlay can hold it — so keying every window on every tick spent
    // N-1 window-server round trips on windows that immediately lost it again.
    // Re-key only when none of them holds it, e.g. after the app was deactivated.
    private func makeOverlayKeyIfNeeded() {
        guard !windows.values.contains(where: { $0.isKeyWindow }) else { return }
        let preferred = NSScreen.main.map(screenKey).flatMap { windows[$0] }
        guard let window = preferred ?? windows.keys.sorted().first.flatMap({ windows[$0] }) else {
            return
        }
        window.makeKeyAndOrderFront(nil)
    }

    private func activateIfNeeded() {
        guard !NSApp.isActive else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func removeWindowsForDisconnectedScreens() {
        let liveKeys = Set(NSScreen.screens.map(screenKey))
        for (key, window) in windows where !liveKeys.contains(key) {
            window.close()
            windows.removeValue(forKey: key)
            appliedFrames.removeValue(forKey: key)
        }
    }

    private func screenKey(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? NSStringFromRect(screen.frame)
    }
}

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

enum OverlayStyle {
    static let backgroundNSColor = NSColor(
        calibratedRed: 28.0 / 255.0,
        green: 31.0 / 255.0,
        blue: 36.0 / 255.0,
        alpha: 1
    )
    static let background = Color(nsColor: backgroundNSColor)
    static let contentWidth: CGFloat = 620
}

final class BreakOverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = true
        backgroundColor = OverlayStyle.backgroundNSColor
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        // Escape intentionally does nothing during a required break.
    }
}

struct BreakOverlayView: View {
    @ObservedObject var appState: AppState
    let breakPrompt: String

    var body: some View {
        ZStack {
            OverlayStyle.background
                .ignoresSafeArea()
            Group {
                if appState.isBreakCompleteAllowed() {
                    completionContent
                } else {
                    breakContent
                }
            }
            .foregroundStyle(.white)
            .frame(width: OverlayStyle.contentWidth)
            .padding(64)
            wallClock
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
            .font(.system(size: 140, weight: .bold, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.top, 12)
            Text(breakPrompt)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 16)
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
                } else {
                    Text("Postponement was already used this cycle. Complete this break to reset it.")
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
                        title: "Skip This Break — +\(formatDurationCompact(EmergencyOverride.focusGrant))",
                        holdDuration: EmergencyOverride.holdDuration
                    ) {
                        appState.useEmergencyOverride()
                    }
                    .frame(width: 320)
                    .padding(.top, 14)
                    Text("Once every 7 days, whatever else is switched on. Spending it breaks your clean streak.")
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
        return "Already used this week. Available again on "
            + DateFormatter.breakGuardDateTime.string(from: availableAt) + "."
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

            continueWorkingContent
        }
    }

    private var continueWorkingContent: some View {
        VStack(spacing: 0) {
            Text("Well rested. Ready when you are.")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 24)
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
            holdDuration: hold
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
