import AppKit
import SwiftUI
import os

@MainActor
final class OverlayScreenManager {
    private weak var appState: AppState?
    private var windows: [String: BreakOverlayWindow] = [:]
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
        for screen in NSScreen.screens {
            let key = screenKey(screen)
            if windows[key] == nil {
                let window = BreakOverlayWindow(screen: screen)
                window.contentView = NSHostingView(rootView: BreakOverlayView(appState: appState))
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
            Text("Stand up, move away from the screen, and rest your eyes.")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .padding(.top, 16)
            HStack(spacing: 16) {
                postponeButton(appState.settings.firstPostponeDuration)
                postponeButton(appState.settings.secondPostponeDuration)
            }
            .padding(.top, 48)

            if appState.isManualBreak {
                Button {
                    appState.cancelManualBreak()
                } label: {
                    Text("Cancel Break")
                        .font(.system(size: 16, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.top, 14)
                Text("You started this break yourself — cancelling restores your remaining focus time.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
            }
        }
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

            if appState.settings.focusTagsEnabled {
                tagSelectionContent
            } else {
                continueWorkingContent
            }
        }
    }

    private var tagSelectionContent: some View {
        VStack(spacing: 0) {
            Text("What were you focused on?")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 28)

            if appState.focusTags.isEmpty {
                Text("No focus tags are configured. You can add them in Settings.")
                    .font(.system(size: 18))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.top, 36)
            } else {
                LazyVGrid(columns: tagColumns, spacing: 14) {
                    ForEach(appState.focusTags) { tag in
                        Button {
                            appState.completeBreak(classification: .tag(id: tag.id))
                        } label: {
                            Text(tag.name)
                                .font(.system(size: 20, weight: .semibold))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }
                }
                .padding(.top, 36)
            }

            Divider()
                .overlay(.white.opacity(0.15))
                .padding(.vertical, 28)

            Button {
                appState.completeBreak(classification: .skipped)
            } label: {
                Text("Skip")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)

            Text("The focus interval and break still count, but no category receives credit.")
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.top, 16)
        }
    }

    private var continueWorkingContent: some View {
        VStack(spacing: 0) {
            Text("Well rested. Ready when you are.")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 24)
            Button {
                appState.completeBreak(classification: .untracked)
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

    // Two equal columns keep tag buttons uniform; an odd last tag stays
    // left-aligned instead of floating centered like the adaptive grid did.
    private var tagColumns: [GridItem] {
        let count = appState.focusTags.count > 1 ? 2 : 1
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    }

    private func postponeButton(_ duration: TimeInterval) -> some View {
        Button {
            appState.postpone(minutes: duration / 60)
        } label: {
            Text("Postpone for \(Int(duration / 60)) minutes")
                .font(.system(size: 18, weight: .medium))
                .frame(maxWidth: .infinity, minHeight: 40)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}
