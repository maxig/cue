import SwiftUI
import AppKit
import Combine

/// Owns the shared `AppState` and the status-bar item. Using an AppDelegate +
/// `NSStatusItem` (instead of SwiftUI's `MenuBarExtra`) lets the menu bar icon
/// distinguish left-click (popover) from right-click (a standard AppKit menu).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusController = StatusItemController(app: appState)
    }
}

/// Manages the menu bar status item: its live icon/timer, the left-click
/// popover hosting `RecorderPopoverView`, and the right-click menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let app: AppState
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var cancellables = Set<AnyCancellable>()

    init(app: AppState) {
        self.app = app
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: RecorderPopoverView().environmentObject(app))

        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        updateButton()

        // Keep the icon/timer in sync with recording state.
        app.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)

        // A recording can begin and end while the popover stays open (Stop lives
        // in a separate floating panel). When we return to idle with the popover
        // still showing, re-arm the live camera + region preview — the popover's
        // SwiftUI view is hosted in a persistent controller, so its `.onAppear`/
        // `.task` won't fire again on their own.
        app.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] newState in
                guard let self, newState == .idle, self.popover.isShown else { return }
                self.app.popoverDidAppear()
            }
            .store(in: &cancellables)
    }

    // MARK: Button

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(systemSymbolName: app.menuBarSymbol, accessibilityDescription: "Cue")?
            .withSymbolConfiguration(config)
        if let title = app.menuBarTitle {
            button.title = " \(title)"
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        } else {
            button.title = ""
        }
    }

    // MARK: Click handling

    @objc private func handleClick() {
        let isRightClick = NSApp.currentEvent.map {
            $0.type == .rightMouseUp || $0.modifierFlags.contains(.control)
        } ?? false
        if isRightClick { showMenu() } else { togglePopover() }
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func showMenu() {
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()
        menu.addItem(item(app.isBusy ? "Stop Recording" : "Start Recording", #selector(toggleRecording)))
        menu.addItem(item("Open Library", #selector(openLibrary)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Cue", #selector(quit), key: "q"))

        // Show under the status item, then clear so left-click still triggers the action.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    // MARK: Menu actions

    @objc private func toggleRecording() { app.toggleRecording() }
    @objc private func openLibrary() { app.openLibrary() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: NSPopoverDelegate

    // The popover's content lives in a persistent NSHostingController, so SwiftUI
    // lifecycle hooks (`.task`, `.onAppear`, `.onDisappear`) only fire once and
    // can't be relied on to start/stop the live preview. Drive it from these
    // AppKit callbacks instead, which fire on every open/close.

    func popoverDidShow(_ notification: Notification) {
        Task { [weak self] in
            guard let self else { return }
            await self.app.refreshEverything()
            self.app.popoverDidAppear()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Always reopen on the recorder, not a stale Settings screen.
        app.showSettings = false
        // Tear the live camera bubble + region rectangle down (no-op mid-recording).
        app.popoverDidDisappear()
    }
}
