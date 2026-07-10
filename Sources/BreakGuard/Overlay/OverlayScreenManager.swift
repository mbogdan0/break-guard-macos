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
        backgroundColor = NSColor(
            calibratedRed: 28.0 / 255.0,
            green: 31.0 / 255.0,
            blue: 36.0 / 255.0,
            alpha: 1
        )
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
    private let tagColumns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 18)]

    var body: some View {
        ZStack {
            Color(red: 28.0 / 255.0, green: 31.0 / 255.0, blue: 36.0 / 255.0)
                .ignoresSafeArea()
            VStack(spacing: 32) {
                if appState.isBreakCompleteAllowed() {
                    completionContent
                } else {
                    Text("Time for a break")
                        .font(.system(size: 56, weight: .semibold))
                    Text(formatClock(appState.breakRemaining()))
                        .font(.system(size: 112, weight: .bold, design: .monospaced))
                    Text("Stand up, move away from the screen, and rest your eyes.")
                        .font(.system(size: 28, weight: .regular))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 20) {
                        Button("Postpone for \(Int(appState.settings.firstPostponeDuration / 60)) minutes") {
                            appState.postpone(minutes: appState.settings.firstPostponeDuration / 60)
                        }
                        .frame(minWidth: 240, minHeight: 56)
                        Button("Postpone for \(Int(appState.settings.secondPostponeDuration / 60)) minutes") {
                            appState.postpone(minutes: appState.settings.secondPostponeDuration / 60)
                        }
                        .frame(minWidth: 240, minHeight: 56)
                    }
                    .controlSize(.large)
                    .font(.system(size: 18, weight: .medium))
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: 980)
            .padding(64)
        }
    }

    private var completionContent: some View {
        VStack(spacing: 28) {
            Text("Break completed")
                .font(.system(size: 56, weight: .semibold))
            Text("What were you focused on?")
                .font(.system(size: 30, weight: .medium))

            if appState.focusTags.isEmpty {
                Text("No focus tags are configured. You can add them in Settings.")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: tagColumns, spacing: 18) {
                    ForEach(appState.focusTags) { tag in
                        Button(tag.name) {
                            appState.completeBreak(classification: .tag(id: tag.id))
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .font(.system(size: 21, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
            }

            Divider()
                .overlay(.white.opacity(0.2))
                .padding(.top, 4)

            Button("Skip") {
                appState.completeBreak(classification: .skipped)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .font(.system(size: 20, weight: .semibold))
            .frame(minWidth: 220, minHeight: 56)
            .keyboardShortcut(.defaultAction)

            Text("The focus interval and break still count, but no category receives credit.")
                .font(.system(size: 17))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
