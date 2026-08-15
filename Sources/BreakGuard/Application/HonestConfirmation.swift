import AppKit

// What a confirmation came back with. `declined` is the user answering Cancel;
// `aborted` is no answer at all — the app took the dialog away, or never opened
// it. A caller whose safe branch is "change nothing" may treat the two alike,
// but a caller that *acts* on a decline has to tell them apart: an abort is not
// the user asking for that action either.
enum HonestAnswer {
    case confirmed
    case declined
    case aborted
}

// All confirmations share one voice: two sentences that appeal to the user's
// honesty about their own health, with the safe choice as Cancel. Shared by the
// status menu and the settings pane so a dialog cannot drift into a different
// tone depending on where it was opened from.
//
// `gate` holds the confirm button disabled for that many seconds, counting down
// on the button itself. Cancel stays live throughout — the gate is on the
// choice the app wants reconsidered, never on backing out.
@MainActor
func confirmHonestly(
    message: String,
    informative: String,
    confirmTitle: String,
    gate: TimeInterval? = nil
) -> HonestAnswer {
    // Never nest. `isConfirmationOpen` is one flag for the whole app, so a
    // second alert's `defer` would clear it while the first is still on screen
    // — leaving that one invisible to abortOpenConfirmation() and the nudge
    // card free to cover it, which is exactly what the flag exists to prevent.
    guard !isConfirmationOpen else { return .aborted }
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = informative
    alert.alertStyle = .informational
    alert.addButton(withTitle: confirmTitle)
    alert.addButton(withTitle: "Cancel")
    let countdown = gate.map { startGateCountdown(on: alert.buttons[0], title: confirmTitle, seconds: $0) }
    isConfirmationOpen = true
    defer {
        countdown?.invalidate()
        isConfirmationOpen = false
    }
    switch alert.runModal() {
    case .alertFirstButtonReturn: return .confirmed
    case .abort: return .aborted
    default: return .declined
    }
}

// Whether a confirmation is on screen right now. The longest gates run three
// minutes, so a break falling due behind one is routine rather than a corner
// case — and it is long enough for the nudge card to be told to keep out of
// its way.
@MainActor private(set) var isConfirmationOpen = false

// Takes the screen back for a break. The overlay sits at `.screenSaver` and
// would otherwise cover the alert while the modal session went on swallowing
// clicks meant for it — a break screen that ignores the mouse, with the only
// way out an Escape key nobody would think to press.
//
// Aborting rather than answering: `runModal()` returns `.abort`, which reaches
// the caller as `.aborted` rather than as a decline. The two are not the same
// question — see HonestAnswer.
//
// Returns whether there was anything to abort. `abortModal()` only unwinds the
// modal loop on its next pass, so a caller about to take the screen has to wait
// out that pass rather than assume the alert is already gone.
@MainActor
@discardableResult
func abortOpenConfirmation() -> Bool {
    guard isConfirmationOpen else { return false }
    isConfirmationOpen = false
    NSApp.abortModal()
    return true
}

// Disables the button and counts it down to zero. The timer is added to
// `.modalPanel` explicitly: `NSAlert.runModal()` does not run the default run
// loop mode, so a `Timer.scheduledTimer` here would never fire and the button
// would stay disabled forever. A disabled default button also ignores Return,
// which is the whole point of the gate.
@MainActor
private func startGateCountdown(on button: NSButton, title: String, seconds: TimeInterval) -> Timer {
    var remaining = max(1, Int(seconds.rounded()))
    button.isEnabled = false
    button.title = gateButtonTitle(title, remaining: remaining)
    let timer = Timer(timeInterval: 1, repeats: true) { timer in
        MainActor.assumeIsolated {
            remaining -= 1
            button.title = gateButtonTitle(title, remaining: remaining)
            guard remaining <= 0 else { return }
            button.isEnabled = true
            timer.invalidate()
        }
    }
    RunLoop.main.add(timer, forMode: .modalPanel)
    return timer
}

// The confirm button's title while its gate runs, and the bare title once the
// count reaches zero — the enabled button should read exactly as it always has,
// with no leftover "(0)" to click past.
//
// The longest gates run three minutes, and "(180)" counting down is a number to
// decode rather than a time to wait out, so from a minute up it switches to
// m:ss — the same shape the settings duration fields use.
func gateButtonTitle(_ base: String, remaining: Int) -> String {
    guard remaining > 0 else { return base }
    guard remaining >= 60 else { return "\(base) (\(remaining))" }
    return "\(base) (\(String(format: "%d:%02d", remaining / 60, remaining % 60)))"
}
