import AppKit
import Combine

/// The app's only permanent user interface: one menu bar item.
///
/// Left click opens the menu; right click (or control-click) toggles the effect
/// on the built-in display without opening it. Titles are refreshed whenever the
/// menu opens and after every action, so the menu always describes the current
/// state rather than the state at launch.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let store: HingeStore
    private let debug: DebugWindowController
    private let onboarding: OnboardingWindowController
    private let settingsWindow: SettingsWindowController
    private let overlay = LiveOverlayController.shared
    private let statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
    private let icon = NSImage(systemSymbolName:"laptopcomputer",accessibilityDescription:"Ajar")
    private var iconRefresh: Timer?
    private let menu = NSMenu()
    private let angleItem = NSMenuItem()
    private let effectItem = NSMenuItem()
    private let permissionItem = NSMenuItem()
    private let debugItem = NSMenuItem()
    private let setupItem = NSMenuItem()
    private let settingsItem = NSMenuItem()
    private var stateObservers: Set<AnyCancellable> = []

    init(store: HingeStore, debug: DebugWindowController, onboarding: OnboardingWindowController,
         settingsWindow: SettingsWindowController) {
        self.store = store
        self.debug = debug
        self.onboarding = onboarding
        self.settingsWindow = settingsWindow
        super.init()
        statusItem.button?.image = icon
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on:[.leftMouseUp,.rightMouseUp])
        menu.autoenablesItems = false
        menu.delegate = self
        angleItem.isEnabled = false
        effectItem.target = self
        effectItem.action = #selector(toggleEffect)
        permissionItem.target = self
        permissionItem.action = #selector(requestPermission)
        debugItem.target = self
        debugItem.action = #selector(showDebug)
        debugItem.keyEquivalent = "d"
        debugItem.keyEquivalentModifierMask = [.command,.shift]
        setupItem.target = self
        setupItem.action = #selector(showOnboarding)
        settingsItem.target = self
        settingsItem.action = #selector(showSettings)
        settingsItem.keyEquivalent = ","
        let quit = NSMenuItem(title:"Quit Ajar",action:#selector(quit),keyEquivalent:"q")
        quit.target = self
        for item in [angleItem, .separator(), effectItem, permissionItem, .separator(), settingsItem, setupItem, debugItem, .separator(), quit] {
            menu.addItem(item)
        }
        // No menu is attached for good: that would make both buttons open it, and
        // the click would never come back to us.
        overlay.$isOpen.sink { [weak self] _ in self?.refresh() }.store(in:&stateObservers)
        overlay.$status.sink { [weak self] _ in self?.refresh() }.store(in:&stateObservers)
        startIconRefresh()
        refresh()
    }

    /// macOS sometimes leaves the item blank on a display that is not the one
    /// currently focused, with the slot reserved but nothing drawn. Re-applying
    /// the image makes the menu bar build that remote view again; the slow timer
    /// covers focus changes, which post no notification of their own.
    private func startIconRefresh() {
        for name in [NSApplication.didChangeScreenParametersNotification,
                     NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self,selector:#selector(refreshIcon),name:name,object:nil)
        }
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(refreshIcon),
                                                          name:NSWorkspace.activeSpaceDidChangeNotification,object:nil)
        iconRefresh = Timer.scheduledTimer(withTimeInterval:5,repeats:true) { [weak self] _ in self?.refreshIcon() }
    }

    @objc private func refreshIcon() {
        statusItem.button?.image = icon
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.appearsDisabled = !overlay.isOpen
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc private func handleClick() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false)
        if secondary { toggleEffect() } else { openMenu() }
    }

    private func openMenu() {
        refresh()
        // Attaching the menu for the duration of the click is the supported way
        // to keep control of the button's own action the rest of the time.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// Used by the launch log to confirm the item really landed in the menu bar.
    var diagnostic: String {
        let button = statusItem.button
        let items = menu.items.map { item in
            item.isSeparatorItem ? "—" : "\(item.title)\(item.state == .on ? "*" : "")\(item.isHidden ? "(hidden)" : "")"
        }
        return "visible=\(statusItem.isVisible) button=\(button != nil) frame=\(button.map { NSStringFromRect($0.window?.frame ?? .zero) } ?? "none") items=[\(items.joined(separator:" | "))]"
    }

    /// Called by the app delegate after a command-line flag changes the state.
    func refresh() {
        // State lives in the icon as well as the menu: a tinted item means the
        // effect is on the built-in display right now.
        // Off is drawn disabled (grey); on is the normal menu bar colour.
        statusItem.button?.appearsDisabled = !overlay.isOpen
        statusItem.button?.contentTintColor = nil
        statusItem.button?.toolTip = overlay.isOpen ? "Hinge — the lid drives the screen (on). Left click for the menu, right click to stop."
                                                  : "Hinge — the lid drives the screen. Left click for the menu, right click to start."
        let snapshot = store.snapshot()
        let frame = PerformanceMetrics.shared.motionFrame
        if let angle = snapshot.sample?.rawAngle {
            angleItem.title = String(format:"Lid %.1f°   ·   travel %+.1f°   ·   blur %.0f%%",angle,frame.signedDelta,frame.blur*100)
        } else {
            angleItem.title = "Waiting for the hinge…"
        }
        let granted = LiveScreenCapture.hasPermission
        let setupDone = onboarding.hasCompletedBefore
        var conditions = EffectPolicy.current
        conditions.setupComplete = setupDone
        if let blocked = EffectPolicy.reasonBlocked(conditions) {
            effectItem.title = blocked
            effectItem.state = .off
        } else {
            effectItem.title = overlay.isOpen ? "Remove effect from the built-in display"
                                              : "Apply effect to the built-in display"
            effectItem.state = overlay.isOpen ? .on : .off
        }
        permissionItem.isHidden = granted || !setupDone
        permissionItem.title = "Open Screen Recording settings…"
        settingsItem.title = setupDone ? "Settings…" : "Settings… (setup unfinished)"
        setupItem.title = setupDone ? "Set Up Ajar…" : "Continue setup…"
        debugItem.title = debug.isOpen ? "Hide Debug Window" : "Show Debug Window…"
    }

    @objc private func showOnboarding() {
        onboarding.show()
        refresh()
    }

    @objc private func showSettings() { settingsWindow.show() }

    @objc private func toggleEffect() {
        var conditions = EffectPolicy.current
        conditions.setupComplete = onboarding.hasCompletedBefore
        // A blocked toggle explains itself rather than doing nothing: unfinished
        // setup opens the walkthrough, a missing permission opens the pane, and a
        // clamshell Mac just says so.
        if !conditions.setupComplete {
            onboarding.show()
            refresh()
            return
        }
        if !conditions.builtInDisplayInUse {
            refresh()
            return
        }
        if !conditions.hasScreenCapturePermission {
            requestPermission()
            return
        }
        if overlay.isOpen { overlay.close() } else { overlay.open(store:store) }
        AjarSettings.shared.effectEnabled = overlay.isOpen
        refresh()
        // The overlay's own state arrives asynchronously; refresh once it lands.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in self?.refresh() }
    }

    @objc private func requestPermission() {
        LiveScreenCapture.requestPermission()
        LiveScreenCapture.openPermissionSettings()
        refresh()
    }

    @objc private func showDebug() {
        debug.toggle()
        refresh()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
