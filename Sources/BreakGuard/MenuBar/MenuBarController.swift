import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let takeBreakItem = NSMenuItem(title: "Take a Break Now", action: #selector(takeBreakNow), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "")
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

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "eye", accessibilityDescription: "BreakGuard")
        image?.isTemplate = true
        button.image = image
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
        menu.addItem(takeBreakItem)

        let pauseMenu = NSMenu(title: "Pause")
        pauseMenu.addItem(actionItem("For 15 Minutes", action: #selector(pauseFor15Minutes)))
        pauseMenu.addItem(actionItem("For 1 Hour", action: #selector(pauseFor1Hour)))
        pauseMenu.addItem(actionItem("For 1.5 Hours", action: #selector(pauseFor90Minutes)))
        pauseMenu.addItem(.separator())
        pauseMenu.addItem(actionItem("Until Tomorrow", action: #selector(pauseUntilTomorrow)))
        pauseItem.submenu = pauseMenu
        menu.addItem(pauseItem)

        resumeItem.target = self
        menu.addItem(resumeItem)
        menu.addItem(.separator())

        let settingsItem = actionItem("Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(actionItem("Quit BreakGuard", action: #selector(quit), keyEquivalent: "q"))
    }

    private func actionItem(
        _ title: String,
        action: Selector,
        keyEquivalent: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func updatePresentation() {
        let presentation = makeMenuPresentation(
            for: appState.timerState,
            showSeconds: appState.settings.showSecondsInMenuBar
        )
        statusItem.button?.title = " \(presentation.menuBarTitle)"
        statusItem.button?.toolTip = presentation.statusTitle
        statusMenuItem.title = presentation.statusTitle

        takeBreakItem.isHidden = presentation.primaryAction != .takeBreak
        pauseItem.isHidden = !presentation.canPause
        resumeItem.isHidden = presentation.primaryAction != .resume
    }

    @objc private func takeBreakNow() {
        appState.takeBreakNow()
    }

    @objc private func pauseFor15Minutes() {
        appState.suspend(minutes: 15)
    }

    @objc private func pauseFor1Hour() {
        appState.suspend(minutes: 60)
    }

    @objc private func pauseFor90Minutes() {
        appState.suspend(minutes: 90)
    }

    @objc private func pauseUntilTomorrow() {
        appState.suspendUntilTomorrow()
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
