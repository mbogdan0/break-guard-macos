import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let takeBreakItem = NSMenuItem(title: "Take a Break Now", action: #selector(takeBreakNow), keyEquivalent: "")
    // "Just Took a Break" is hidden for now — this is deliberate, not a bug.
    // Only the menu wiring is commented out (here, in configureMenu(), and in
    // updatePresentation()); the action and the domain path behind it
    // (AppState.markBreakTaken -> StateMachine.markBreakTaken) are kept intact
    // and still covered by tests, so restoring the item is an uncomment.
    // private let justTookBreakItem = NSMenuItem(title: "Just Took a Break", action: #selector(justTookBreak), keyEquivalent: "")
    private let extendItem = NSMenuItem(title: "Extend Focus", action: nil, keyEquivalent: "")
    private var extendOptionItems: [(item: NSMenuItem, baseTitle: String, minutes: Double)] = []
    private let pauseItem = NSMenuItem(title: "Pause Until 9 AM", action: #selector(pauseUntilMorning), keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "Resume Now", action: #selector(resumeNow), keyEquivalent: "")
    private var cancellables = Set<AnyCancellable>()
    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        super.init()
        configureStatusItem()
        configureMenu()

        Publishers.CombineLatest(appState.$timerState, appState.$settings)
            .sink { [weak self] _, _ in self?.updatePresentation() }
            .store(in: &cancellables)
        updatePresentation()
    }

    func menuWillOpen(_ menu: NSMenu) {
        updatePresentation()
    }

    // The menus autoenable their items, so this is where the extend options
    // grey out once harder mode's single normal skip action is spent.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if extendOptionItems.contains(where: { $0.item === menuItem }) {
            return appState.canExtendFocus
        }
        return true
    }

    private static let templateEyeImage: NSImage? = {
        let image = NSImage(systemSymbolName: "eye", accessibilityDescription: "BreakGuard")
        image?.isTemplate = true
        return image
    }()

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = Self.templateEyeImage
        button.imagePosition = .imageLeading
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    }

    private func configureMenu() {
        menu.delegate = self
        statusItem.menu = menu

        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        takeBreakItem.target = self
        takeBreakItem.image = Self.menuImage("cup.and.saucer")
        menu.addItem(takeBreakItem)

        // Hidden temporarily — see the justTookBreakItem declaration above.
        // justTookBreakItem.target = self
        // justTookBreakItem.image = Self.menuImage("checkmark.circle")
        // menu.addItem(justTookBreakItem)

        let extendMenu = NSMenu(title: "Extend Focus")
        let extendOptions: [(title: String, minutes: Double, action: Selector)] = [
            ("By 15 Minutes", 15, #selector(extendBy15Minutes)),
            ("By 35 Minutes", 35, #selector(extendBy35Minutes)),
            ("By 45 Minutes", 45, #selector(extendBy45Minutes)),
            ("By 1 Hour 5 Minutes", 65, #selector(extendBy65Minutes))
        ]
        for option in extendOptions {
            let item = actionItem(option.title, action: option.action)
            extendMenu.addItem(item)
            extendOptionItems.append((item, option.title, option.minutes))
        }
        extendItem.submenu = extendMenu
        extendItem.image = Self.menuImage("hourglass")
        menu.addItem(extendItem)

        pauseItem.target = self
        pauseItem.image = Self.menuImage("pause.circle")
        menu.addItem(pauseItem)

        resumeItem.target = self
        resumeItem.image = Self.menuImage("play.circle")
        menu.addItem(resumeItem)
        menu.addItem(.separator())

        let settingsItem = actionItem("Settings…", action: #selector(showSettings), keyEquivalent: ",", symbol: "gearshape")
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit BreakGuard", action: #selector(quit), keyEquivalent: "q", symbol: "power"))
    }

    // System-symbol images are template by default, so they render monochrome
    // and adapt to the menu's light/dark appearance.
    private static func menuImage(_ symbolName: String) -> NSImage? {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        symbol: String? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        if let symbol {
            item.image = Self.menuImage(symbol)
        }
        return item
    }

    private func updatePresentation() {
        let presentation = makeMenuPresentation(
            for: appState.timerState,
            showSeconds: appState.settings.showSecondsInMenuBar,
            coarseSeconds: appState.settings.coarseSecondsInMenuBar,
            warningLeadTime: appState.settings.warningLeadTime,
            focusExtended: appState.isFocusExtended,
            outsideWorkingHours: appState.settings.isOutsideWorkingHours(at: Date())
        )
        if let button = statusItem.button {
            switch presentation.emphasis {
            case .none:
                button.image = Self.templateEyeImage
                button.imagePosition = .imageLeading
                button.title = " \(presentation.menuBarTitle)"
            case .caution, .urgent:
                // The menu bar tints button text through its own template/vibrancy
                // pipeline, which flattens explicit text colors. A pre-rendered,
                // non-template image is displayed with its original colors.
                button.image = statusPillImage(
                    countdown: presentation.menuBarTitle,
                    style: presentation.emphasis == .urgent ? .urgent : .caution
                )
                button.imagePosition = .imageOnly
                button.title = ""
            }
            button.toolTip = presentation.statusTitle
        }
        statusMenuItem.title = presentation.statusTitle

        takeBreakItem.isHidden = presentation.primaryAction != .takeBreak
        // Hidden temporarily — see the justTookBreakItem declaration above.
        // justTookBreakItem.isHidden = presentation.primaryAction != .takeBreak
        extendItem.isHidden = !presentation.canExtend
        pauseItem.isHidden = presentation.primaryAction != .takeBreak
        resumeItem.isHidden = presentation.primaryAction != .resume
        updateExtendOptionTitles()
    }

    // Each extend option shows the focus end time it would produce, greyed
    // out next to the duration.
    private func updateExtendOptionTitles() {
        let deadline = currentFocusDeadline()
        for (item, baseTitle, minutes) in extendOptionItems {
            guard let deadline else {
                item.attributedTitle = nil
                item.title = baseTitle
                continue
            }
            item.attributedTitle = makeExtendFocusTitle(
                baseTitle: baseTitle,
                deadline: deadline,
                minutes: minutes
            )
        }
    }

    private func currentFocusDeadline() -> Date? {
        focusDeadline(for: appState.timerState)
    }

    private struct StatusPillStyle {
        let background: NSColor
        let foreground: NSColor

        static let urgent = StatusPillStyle(background: .systemRed, foreground: .white)
        // A muted ochre-amber: clearly a warning, but dimmer and warmer than
        // systemRed so the red pill keeps its alarm value.
        static let caution = StatusPillStyle(
            background: NSColor(srgbRed: 0.702, green: 0.478, blue: 0.075, alpha: 1),
            foreground: .white
        )
    }

    private func statusPillImage(countdown: String, style: StatusPillStyle) -> NSImage {
        let text = NSAttributedString(
            string: countdown,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                .foregroundColor: style.foreground
            ]
        )
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [style.foreground]))
        let icon = NSImage(systemSymbolName: "eye", accessibilityDescription: "BreakGuard")?
            .withSymbolConfiguration(symbolConfiguration)
        let textSize = text.size()
        let iconSize = icon?.size ?? .zero
        let spacing: CGFloat = 5
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 2
        let size = NSSize(
            width: horizontalPadding + iconSize.width + spacing + ceil(textSize.width) + horizontalPadding,
            height: max(iconSize.height, ceil(textSize.height)) + verticalPadding * 2
        )
        let image = NSImage(size: size, flipped: false) { rect in
            style.background.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            icon?.draw(
                at: NSPoint(x: horizontalPadding, y: (rect.height - iconSize.height) / 2),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            text.draw(at: NSPoint(
                x: horizontalPadding + iconSize.width + spacing,
                y: (rect.height - textSize.height) / 2
            ))
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func takeBreakNow() {
        appState.takeBreakNow()
    }

    // All confirmations share one voice: two sentences that appeal to the
    // user's honesty about their own health, with the safe choice as Cancel.
    private func confirmHonestly(message: String, informative: String, confirmTitle: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.alertStyle = .informational
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func justTookBreak() {
        let confirmed = confirmHonestly(
            message: "Did you really take a break? 👀",
            informative: "Confirm only if you truly rested away from the screen — nothing is logged, so the only person you can cheat is yourself. Your eyes are keeping the real score.",
            confirmTitle: "Yes, I Took a Break"
        )
        if confirmed {
            appState.markBreakTaken()
        }
    }

    @objc private func extendBy15Minutes() {
        appState.extendFocus(minutes: 15)
    }

    @objc private func extendBy35Minutes() {
        confirmLongExtension(minutes: 35, label: "35 minutes")
    }

    @objc private func extendBy45Minutes() {
        confirmLongExtension(minutes: 45, label: "45 minutes")
    }

    @objc private func extendBy65Minutes() {
        confirmLongExtension(minutes: 65, label: "1 hour 5 minutes")
    }

    private func confirmLongExtension(minutes: Double, label: String) {
        let confirmed = confirmHonestly(
            message: "Extend focus by \(label)? ⏳",
            informative: "That is a long stretch without rest, and your eyes will pay the bill later. Be honest — do you really need this, or is the break the healthier choice?",
            confirmTitle: "Extend Anyway"
        )
        if confirmed {
            appState.extendFocus(minutes: minutes)
        }
    }

    @objc private func pauseUntilMorning() {
        guard let resumeDate = appState.nextMorningResumeDate() else { return }
        let time = DateFormatter.breakGuardTime.string(from: resumeDate)
        let day = Calendar.current.isDateInToday(resumeDate) ? "today" : "tomorrow"
        let confirmed = confirmHonestly(
            message: "Pause reminders until \(time) \(day)? 🌙",
            informative: "This silences every break reminder until \(time) \(day) — a promise that you are done straining your eyes for the day. Don't use it to keep working unguarded: your health is what's on the line.",
            confirmTitle: "Pause Until \(time)"
        )
        if confirmed {
            appState.pauseUntilNextMorning()
        }
    }

    @objc private func resumeNow() {
        appState.resumeNow()
    }

    @objc private func showSettings() {
        appState.showSettings()
    }

    @objc private func quit() {
        let confirmed = confirmHonestly(
            message: "Quit BreakGuard? 🛑",
            informative: "With BreakGuard off, nothing stands between your eyes and the next marathon screen session. Be honest — quit only if you are truly stepping away, not dodging your breaks.",
            confirmTitle: "Quit Anyway"
        )
        if confirmed {
            NSApp.terminate(nil)
        }
    }
}

func makeExtendFocusTitle(
    baseTitle: String,
    deadline: Date,
    minutes: Double,
    timeFormatter: DateFormatter = .breakGuardTime
) -> NSAttributedString {
    let title = NSMutableAttributedString(
        string: baseTitle,
        attributes: [.font: NSFont.menuFont(ofSize: 0)]
    )
    let extendedEnd = deadline.addingTimeInterval(minutes * 60)
    title.append(NSAttributedString(
        string: "  —  until \(timeFormatter.string(from: extendedEnd))",
        attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
    ))
    return title
}

func focusDeadline(for state: TimerState) -> Date? {
    switch state {
    case let .working(deadline, _), let .warning(deadline), let .postponed(deadline):
        return deadline
    default:
        return nil
    }
}
