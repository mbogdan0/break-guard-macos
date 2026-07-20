import AppKit
import SwiftUI
import os

@MainActor
final class OverlayScreenManager {
    private weak var appState: AppState?
    private var windows: [String: BreakOverlayWindow] = [:]
    private var currentBreakPrompt: String?
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
            windows[key]?.setFrame(screen.frame, display: true)
            windows[key]?.makeKeyAndOrderFront(nil)
        }
        removeWindowsForDisconnectedScreens()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func updateForScreenChanges() {
        guard !windows.isEmpty else { return }
        showOnAllScreens()
    }

    func bringToFront() {
        for window in windows.values {
            window.level = .screenSaver
            window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideAll() {
        if !windows.isEmpty {
            logger.info("Overlay dismissed")
        }
        for window in windows.values {
            window.orderOut(nil)
        }
        windows.removeAll()
        currentBreakPrompt = nil
    }

    private func removeWindowsForDisconnectedScreens() {
        let liveKeys = Set(NSScreen.screens.map(screenKey))
        for (key, window) in windows where !liveKeys.contains(key) {
            window.close()
            windows.removeValue(forKey: key)
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
        }
    }

    private var breakContent: some View {
        VStack(spacing: 0) {
            Text("Time for a break")
                .font(.system(size: 44, weight: .semibold))
            Text(formatClock(appState.breakRemaining()))
                .font(.system(size: 112, weight: .bold, design: .monospaced))
                .padding(.top, 12)
            Text(breakPrompt)
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            if breakOverlayActionSet(isManualBreak: appState.isManualBreak) == .cancel {
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
                HStack(spacing: 16) {
                    postponeButton(first, comparedTo: second)
                    postponeButton(second, comparedTo: first)
                }
                .padding(.top, 48)
                Text("Hold a button down to postpone.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 8)
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
            Text(formatClock(appState.totalRestTime()))
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
        HoldToConfirmButton(
            title: "Postpone for \(formatDurationCompact(duration))",
            holdDuration: postponeHoldDuration(
                for: duration,
                comparedTo: other,
                penalized: appState.isPostponePenalized
            )
        ) {
            appState.postpone(seconds: duration)
        }
    }
}

enum BreakOverlayActionSet: Equatable {
    case cancel
    case postpone
}

func breakOverlayActionSet(isManualBreak: Bool) -> BreakOverlayActionSet {
    isManualBreak ? .cancel : .postpone
}
