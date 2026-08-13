import AppKit
import SwiftUI
import os

// The non-blocking half of the break enforcement: a light click-through veil
// over every screen plus a card that keeps coming back. Nothing here ever
// takes a click away from the app underneath, and nothing here ever holds the
// display awake — that is a break's job, not a nudge's.
//
// Structured like OverlayScreenManager on purpose: the same per-screen
// dictionary, the same applied-frame guard, the same slow re-assert cadence.
// This is re-entered on every one-second tick for as long as the pressure
// runs, which can be hours, so every step has to cost nothing when nothing
// changed.
@MainActor
final class NudgeWindowManager {
    private weak var appState: AppState?
    private var veils: [String: NudgeVeilWindow] = [:]
    // Compared against instead of the live frame for the same reason the break
    // overlay does it: AppKit may hand back an adjusted rect.
    private var appliedFrames: [String: NSRect] = [:]
    private var cardWindow: NudgeCardWindow?
    // What the card currently renders. A change rebuilds its content; equal
    // values leave the hosting view alone.
    private var cardPresentation: NudgePresentation?
    // Whether the window has been resized to fit the current content.
    private var cardSized = false
    // Ticks until window order is re-asserted even though nothing looks
    // displaced. Same reasoning and cadence as the break overlay's.
    private var reassertCountdown = 0
    private static let reassertInterval = 10
    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "Nudge")

    init(appState: AppState) {
        self.appState = appState
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateForScreenChanges),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func show(_ presentation: NudgePresentation, showCard: Bool) {
        // The veils go first and the card follows, because they share a window
        // level: a veil ordered front on a re-assert tick lands on top of the
        // card, and the card is the half that has to stay readable.
        let reasserted = showVeils()
        if showCard {
            presentCard(presentation, reassert: reasserted)
        } else {
            hideCard()
        }
    }

    func hideAll() {
        if !veils.isEmpty {
            logger.info("Pressure veil dismissed")
        }
        for window in veils.values {
            window.orderOut(nil)
        }
        veils.removeAll()
        appliedFrames.removeAll()
        reassertCountdown = 0
        hideCard()
        // The card window is kept across a dismissal — it comes back every two
        // minutes and rebuilding it each time would be waste — but not across
        // the end of a pressure window. Its content view holds the root
        // SwiftUI view, which holds AppState, which holds this manager: a
        // retain cycle that is harmless while AppState lives for the life of
        // the app, and pointless to keep for a window nothing is going to ask
        // for again soon.
        cardWindow?.close()
        cardWindow = nil
        cardPresentation = nil
        cardSized = false
    }

    @objc private func updateForScreenChanges() {
        guard !veils.isEmpty else { return }
        showVeils()
        // The card is placed once, when it becomes visible. Unplugging the
        // display it was placed on would otherwise leave it parked off-screen
        // until the next time it is dismissed and returns.
        if let cardWindow, cardWindow.isVisible {
            cardWindow.positionOnMainScreen()
        }
    }

    // Returns whether window order was re-asserted on this tick, so the card
    // can follow the veils back to the front.
    @discardableResult
    private func showVeils() -> Bool {
        var ordered = false
        for screen in NSScreen.screens {
            let key = screenKey(screen)
            if veils[key] == nil {
                veils[key] = NudgeVeilWindow(screen: screen)
                logger.info("Pressure veil window created")
            }
            guard let window = veils[key] else { continue }
            if appliedFrames[key] != screen.frame {
                window.setFrame(screen.frame, display: true)
                appliedFrames[key] = screen.frame
            }
            if !window.isVisible {
                window.orderFrontRegardless()
                ordered = true
            }
        }
        removeVeilsForDisconnectedScreens()
        return reassertOrderIfDue() || ordered
    }

    // The veil sits at .screenSaver so a full-screen app cannot hide it, which
    // means anything else parked at that level can cover it instead. Re-assert
    // on a slow cadence rather than every tick: ordering a window front is a
    // synchronous window-server round trip per window, and the veil draws
    // nothing that could have changed in the meantime.
    @discardableResult
    private func reassertOrderIfDue() -> Bool {
        reassertCountdown -= 1
        let reassert = reassertCountdown <= 0
        if reassert {
            reassertCountdown = Self.reassertInterval
        }
        var ordered = false
        for window in veils.values {
            var displaced = false
            if window.level != .screenSaver {
                window.level = .screenSaver
                displaced = true
            }
            if displaced || reassert {
                window.orderFrontRegardless()
                ordered = true
            }
        }
        return ordered
    }

    private func presentCard(_ presentation: NudgePresentation, reassert: Bool) {
        guard let appState else { return }
        if cardWindow == nil {
            cardWindow = NudgeCardWindow()
        }
        guard let window = cardWindow else { return }
        if cardPresentation != presentation {
            cardPresentation = presentation
            cardSized = false
            window.contentView = NudgeCardHostingView(
                rootView: NudgeCardView(appState: appState, presentation: presentation)
            )
        }
        // The card's height depends on the length of its message, so it is
        // measured rather than fixed. A hosting view that has not laid out yet
        // reports zero, and committing that would leave the panel at its
        // placeholder size with the message clipped — so a zero measurement
        // leaves cardSized false and the next tick asks again.
        if !cardSized, let fitting = window.contentView?.fittingSize, fitting.height > 0 {
            window.setContentSize(fitting)
            cardSized = true
        }
        // Logged here rather than at window creation: the window outlives each
        // dismissal, so creation happens once while the card comes back every
        // BreakPressure.cardReturnInterval, and only the latter is observable.
        if !window.isVisible {
            window.positionOnMainScreen()
            window.orderFrontRegardless()
            logger.info("Nudge card shown")
        } else if reassert {
            window.orderFrontRegardless()
        }
    }

    private func hideCard() {
        guard let cardWindow, cardWindow.isVisible else { return }
        cardWindow.orderOut(nil)
        logger.info("Nudge card hidden")
    }

    private func removeVeilsForDisconnectedScreens() {
        let liveKeys = Set(NSScreen.screens.map(screenKey))
        for (key, window) in veils where !liveKeys.contains(key) {
            window.close()
            veils.removeValue(forKey: key)
            appliedFrames.removeValue(forKey: key)
        }
    }

    private func screenKey(_ screen: NSScreen) -> String {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? NSStringFromRect(screen.frame)
    }
}

// Draws nothing but a wash of black. `ignoresMouseEvents` is what makes this a
// nudge rather than a block: every click, drag, and scroll goes straight
// through to whatever is underneath.
final class NudgeVeilWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        hasShadow = false
        backgroundColor = NSColor.black.withAlphaComponent(BreakPressure.veilOpacity)
        ignoresMouseEvents = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// The card does take clicks — but never the app's activation. A
// `.nonactivatingPanel` lets its buttons work while the keystrokes keep going
// to whatever the user was typing in.
final class NudgeCardWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: NudgeCardStyle.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        isOpaque = false
        hasShadow = true
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // Draggable, so it can be pushed aside without being dismissed.
        isMovableByWindowBackground = true
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Upper middle rather than dead center: squarely in the field of view,
    // without landing on the line of text being worked on.
    // NSScreen.main follows key focus, which an app that never activates does
    // not hold — so it can be nil here, and a card at the window origin would
    // sit in the corner of the bottom-left display.
    func positionOnMainScreen() {
        guard let frame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        setFrameOrigin(NSPoint(
            x: frame.midX - self.frame.width / 2,
            y: frame.minY + (frame.height - self.frame.height) * 0.62
        ))
    }
}

// Without this the first click on an inactive panel is spent activating it
// instead of pressing the button under the pointer — which for the hold button
// means the hold silently never starts.
final class NudgeCardHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

enum NudgeCardStyle {
    static let width: CGFloat = 420
}

struct NudgeCardView: View {
    @ObservedObject var appState: AppState
    let presentation: NudgePresentation
    @State private var overrideExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(presentation.title)
                    .font(.system(size: 17, weight: .semibold))
                Spacer(minLength: 12)
                Button {
                    appState.dismissNudgeCard()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Hide for \(formatDurationCompact(BreakPressure.cardReturnInterval))")
            }

            Text(presentation.message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Button {
                appState.takeBreakNow()
            } label: {
                Text(presentation.primaryTitle)
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 18)

            overrideSection
                .padding(.top, 14)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(width: NudgeCardStyle.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OverlayStyle.background)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.12))
                )
        )
    }

    // The same understated disclosure the break overlay uses, spending the
    // same weekly quota — see StateMachine.spendOverrideOnPressure().
    private var overrideSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    overrideExpanded.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Text("Emergency override")
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(overrideExpanded ? 90 : 0))
                }
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.35))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if overrideExpanded {
                if appState.canSpendOverrideOnPressure {
                    HoldToConfirmButton(
                        title: "Work Unguarded — \(formatDurationCompact(EmergencyOverride.focusGrant))",
                        subtitle: postponeHoldHint(EmergencyOverride.holdDuration),
                        holdDuration: EmergencyOverride.holdDuration
                    ) {
                        appState.spendPressureOverride()
                    }
                    .padding(.top, 10)
                    Text("Once every 7 days, shared with the override on the break screen. Your breaks keep running — only the dimming stops.")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                } else {
                    Text(unavailableText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.45))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
            }
        }
    }

    private var unavailableText: String {
        guard let availableAt = appState.emergencyOverrideAvailableAt else {
            return "Not available right now."
        }
        return "Already used this week. Available again on "
            + DateFormatter.breakGuardDateTime.string(from: availableAt) + "."
    }
}
