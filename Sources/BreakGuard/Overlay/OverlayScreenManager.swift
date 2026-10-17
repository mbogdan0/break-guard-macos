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
    // Slack over the break itself. Not a budget for how long the overlay may
    // stay up — the completion screen has no bound and `hold` renews itself —
    // only how long a leaked assertion could outlive a teardown that never ran.
    private static let assertionSlack: TimeInterval = 5 * 60
    private let displaySleep = DisplaySleepAssertion()
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
        displaySleep.hold(timeout: appState.settings.breakDuration + Self.assertionSlack)
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
        if !appState.isHoldingOverlayAction {
            makeOverlayKeyIfNeeded()
            activateIfNeeded()
        }
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
        // Reordering or changing focus during a gesture can interrupt tracking.
        // Keep the pending reassertion until the pointer is released.
        guard appState?.isHoldingOverlayAction != true else { return }
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
        // Unconditional, and before the early-out on an empty window list: this
        // is the one path that ends the assertion, and it also runs on quit.
        displaySleep.release()
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
