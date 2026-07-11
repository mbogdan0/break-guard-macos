import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let takeBreakItem = NSMenuItem(title: "Take a Break Now", action: #selector(takeBreakNow), keyEquivalent: "")
    private let justTookBreakItem = NSMenuItem(title: "Just Took a Break", action: #selector(justTookBreak), keyEquivalent: "")
    private let extendItem = NSMenuItem(title: "Extend Focus", action: nil, keyEquivalent: "")
    private var extendOptionItems: [(item: NSMenuItem, baseTitle: String, minutes: Double)] = []
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

        justTookBreakItem.target = self
        justTookBreakItem.image = Self.menuImage("checkmark.circle")
        menu.addItem(justTookBreakItem)

        let extendMenu = NSMenu(title: "Extend Focus")
        let extendOptions: [(title: String, minutes: Double, action: Selector)] = [
            ("By 15 Minutes", 15, #selector(extendBy15Minutes)),
            ("By 35 Minutes", 35, #selector(extendBy35Minutes)),
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
            showSeconds: appState.settings.showSecondsInMenuBar
        )
        if let button = statusItem.button {
            if presentation.isUrgent {
                // The menu bar tints button text through its own template/vibrancy
                // pipeline, which flattens explicit text colors. A pre-rendered,
                // non-template image is displayed with its original colors.
                button.image = urgentStatusImage(countdown: presentation.menuBarTitle)
                button.imagePosition = .imageOnly
                button.title = ""
            } else {
                button.image = Self.templateEyeImage
                button.imagePosition = .imageLeading
                button.title = " \(presentation.menuBarTitle)"
            }
            button.toolTip = presentation.statusTitle
        }
        statusMenuItem.title = presentation.statusTitle

        takeBreakItem.isHidden = presentation.primaryAction != .takeBreak
        justTookBreakItem.isHidden = presentation.primaryAction != .takeBreak
        extendItem.isHidden = !presentation.canExtend
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

    private func urgentStatusImage(countdown: String) -> NSImage {
        let text = NSAttributedString(
            string: countdown,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
                .foregroundColor: NSColor.systemRed
            ]
        )
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: NSFont.systemFontSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
        let icon = NSImage(systemSymbolName: "eye", accessibilityDescription: "BreakGuard")?
            .withSymbolConfiguration(symbolConfiguration)
        let textSize = text.size()
        let iconSize = icon?.size ?? .zero
        let spacing: CGFloat = 5
        let size = NSSize(
            width: iconSize.width + spacing + ceil(textSize.width),
            height: max(iconSize.height, ceil(textSize.height))
        )
        let image = NSImage(size: size, flipped: false) { rect in
            icon?.draw(
                at: NSPoint(x: 0, y: (rect.height - iconSize.height) / 2),
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            text.draw(at: NSPoint(x: iconSize.width + spacing, y: (rect.height - textSize.height) / 2))
            return true
        }
        image.isTemplate = false
        return image
    }

    @objc private func takeBreakNow() {
        appState.takeBreakNow()
    }

    @objc private func justTookBreak() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Did you really take a break?"
        alert.informativeText = "This restarts the work timer as if a full break just ended. Nothing is added to your statistics — no focus time, no streaks. Use it only when you truly rested away from the screen. Be honest: your eyes are the ones keeping score."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Yes, I Took a Break")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            appState.markBreakTaken()
        }
    }

    @objc private func extendBy15Minutes() {
        appState.extendFocus(minutes: 15)
    }

    @objc private func extendBy35Minutes() {
        confirmLongExtension(minutes: 35, label: "35 minutes")
    }

    @objc private func extendBy65Minutes() {
        confirmLongExtension(minutes: 65, label: "1 hour 5 minutes")
    }

    private func confirmLongExtension(minutes: Double, label: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Extend focus by \(label)?"
        alert.informativeText = "That is a long stretch without rest. Every extension is rest you take away from yourself — your eyes and posture pay for it later. If you can pause now, taking the break is the healthier choice."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Extend Anyway")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            appState.extendFocus(minutes: minutes)
        }
    }

    @objc private func resumeNow() {
        appState.resumeNow()
    }

    @objc private func showSettings() {
        appState.showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
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
