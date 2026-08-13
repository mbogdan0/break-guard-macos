import AppKit

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
) -> Bool {
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
    // Anything but the confirm button — including an abort — is the safe
    // branch at every call site.
    return alert.runModal() == .alertFirstButtonReturn
}

// Whether a confirmation is on screen right now. The gates run for up to 40
// seconds, which is long enough for a break to fall due behind one — and long
// enough for the nudge card to be told to keep out of its way.
@MainActor private(set) var isConfirmationOpen = false

// Takes the screen back for a break. The overlay sits at `.screenSaver` and
// would otherwise cover the alert while the modal session went on swallowing
// clicks meant for it — a break screen that ignores the mouse, with the only
// way out an Escape key nobody would think to press.
//
// Aborting rather than answering: `runModal()` returns `.abort`, which is not
// the confirm button, so every caller takes the branch that changes nothing.
@MainActor
func abortOpenConfirmation() {
    guard isConfirmationOpen else { return }
    isConfirmationOpen = false
    NSApp.abortModal()
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

// The confirm button's title while its gate runs. Parenthesised seconds, and
// the bare title once the count reaches zero — the enabled button should read
// exactly as it always has, with no leftover "(0)" to click past.
func gateButtonTitle(_ base: String, remaining: Int) -> String {
    remaining > 0 ? "\(base) (\(remaining))" : base
}
