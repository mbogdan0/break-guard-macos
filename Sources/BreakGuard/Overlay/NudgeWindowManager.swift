import AppKit
import SwiftUI
import os

// A recurring card without a screen veil. It never holds the display awake
// or takes activation away from the app the user is working in.
@MainActor
final class NudgeWindowManager {
    private weak var appState: AppState?
    private var cardWindow: NudgeCardWindow?
    private var cardPresentation: NudgePresentation?
    private var appliedSize: NSSize?
    private var reassertCountdown = 0
    private static let reassertInterval = 2
    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "Nudge")

    init(appState: AppState) {
        self.appState = appState
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateForScreenChanges),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceCenter.addObserver(
            self,
            selector: #selector(bringCardToFront),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        workspaceCenter.addObserver(
            self,
            selector: #selector(bringCardToFront),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    func show(_ presentation: NudgePresentation, showCard: Bool) {
        guard showCard else {
            hideCard()
            return
        }
        guard let appState else { return }
        if cardWindow == nil { cardWindow = NudgeCardWindow() }
        guard let window = cardWindow else { return }
        if cardPresentation != presentation {
            cardPresentation = presentation
            appliedSize = nil
            window.contentView = NudgeCardHostingView(
                rootView: NudgeCardView(appState: appState, presentation: presentation)
            )
        }
        // Re-measure after a disclosure changes too. A zero size means the
        // hosting view has not laid out yet, so the next tick retries.
        if let fitting = window.contentView?.fittingSize,
           fitting.height > 0, fitting != appliedSize {
            window.setContentSize(fitting)
            appliedSize = fitting
            if window.isVisible { window.positionOnMainScreen() }
        }
        reassertCountdown -= 1
        let displaced = window.level != NudgeCardWindow.frontLevel
        if displaced { window.level = NudgeCardWindow.frontLevel }
        if !window.isVisible {
            window.positionOnMainScreen()
            window.orderFrontRegardless()
            reassertCountdown = Self.reassertInterval
            logger.info("Nudge card shown")
        } else if displaced || reassertCountdown <= 0 {
            bringCardToFront()
        }
    }

    func hideAll() {
        hideCard()
        cardWindow?.close()
        cardWindow = nil
        cardPresentation = nil
        appliedSize = nil
    }

    @objc private func updateForScreenChanges() {
        guard let cardWindow, cardWindow.isVisible else { return }
        cardWindow.positionOnMainScreen()
        bringCardToFront()
    }

    // Restore order immediately after app or Space changes, with the tick as
    // a backstop for other windows appearing at the same level.
    @objc private func bringCardToFront() {
        guard !isConfirmationOpen, let cardWindow, cardWindow.isVisible else { return }
        if cardWindow.level != NudgeCardWindow.frontLevel {
            cardWindow.level = NudgeCardWindow.frontLevel
        }
        cardWindow.orderFrontRegardless()
        reassertCountdown = Self.reassertInterval
    }

    private func hideCard() {
        reassertCountdown = 0
        guard let cardWindow, cardWindow.isVisible else { return }
        cardWindow.orderOut(nil)
        logger.info("Nudge card hidden")
    }
}

// The card does take clicks — but never the app's activation. A
// `.nonactivatingPanel` lets its buttons work while the keystrokes keep going
// to whatever the user was typing in.
final class NudgeCardWindow: NSPanel {
    static let frontLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

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
        level = Self.frontLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovable = false
        isMovableByWindowBackground = false
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

private struct NudgePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, minHeight: OverlayStyle.compactButtonHeight)
            .background(OverlayStyle.buttonShape.fill(.tint))
            .overlay(OverlayStyle.buttonShape.strokeBorder(.white.opacity(0.25)))
            .contentShape(OverlayStyle.buttonShape)
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct NudgeCardView: View {
    @ObservedObject var appState: AppState
    let presentation: NudgePresentation
    @State private var overrideExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(presentation.title)
                .font(.system(size: 17, weight: .semibold))

            Text(presentation.message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            Button {
                appState.takeBreakNow()
            } label: {
                Text(presentation.primaryTitle)
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(NudgePrimaryButtonStyle())
            .padding(.top, 18)

            HoldToConfirmButton(
                title: "Dismiss for 1 min",
                subtitle: postponeHoldHint(BreakPressure.dismissHoldDuration),
                holdDuration: BreakPressure.dismissHoldDuration
            ) {
                appState.dismissNudgeCard()
            }
            .controlSize(.small)
            .padding(.top, 10)

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
                        title: "Pause Reminders — \(formatDurationCompact(EmergencyOverride.focusGrant))",
                        subtitle: postponeHoldHint(EmergencyOverride.holdDuration),
                        holdDuration: EmergencyOverride.holdDuration
                    ) {
                        appState.spendPressureOverride()
                    }
                    .controlSize(.small)
                    .padding(.top, 10)
                    Text("Once every 7 days, shared with the override on the break screen. Your breaks keep running; these reminders pause.")
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
        // The wait rather than the date — same wording as the break overlay's.
        return "Already used this week. Available again in "
            + formatTimeUntilPhrase(availableAt.timeIntervalSinceNow) + "."
    }
}
