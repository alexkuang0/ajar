import AppKit
import Combine
import SwiftUI

@main
struct AjarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        // A menu bar app with no window of its own. The debug window is created
        // on demand by DebugWindowController, so nothing appears at launch, and
        // the Settings scene exists only to satisfy the App protocol.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = HingeStore()
    private lazy var debug = DebugWindowController(store:store)
    private lazy var onboarding: OnboardingWindowController = {
        let controller = OnboardingWindowController(store:store)
        OnboardingWindowController.shared = controller
        return controller
    }()
    private lazy var settingsWindow: SettingsWindowController = {
        let controller = SettingsWindowController(store:store)
        SettingsWindowController.shared = controller
        return controller
    }()
    private var settingsObserver: AnyCancellable?
    private var menuBar: MenuBarController?
    private var supervisor: EffectSupervisor?
    private var sweep: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: menu bar item only, no Dock icon, no app menu bar of its own.
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--assume-no-built-in-display") {
            HingeCapability.ignoreBuiltInDisplay = true
        }
        menuBar = MenuBarController(store:store,debug:debug,onboarding:onboarding,settingsWindow:settingsWindow)
        // Closing the lid onto an external monitor takes the panel away; the
        // supervisor brings the effect down with it and says so.
        supervisor = EffectSupervisor(store:store,overlay:LiveOverlayController.shared,
                                      settings:AjarSettings.shared,onboarding:onboarding)
        supervisor?.onChange = { [weak self] in self?.menuBar?.refresh() }
        store.start()
        // The overlay renders from the stored settings, so a user who never opens
        // the debug window still gets the camera position they chose.
        LiveSettings.shared.publish(AjarSettings.shared.renderSettings)
        settingsObserver = AjarSettings.shared.objectWillChange.sink { [weak self] _ in
            // objectWillChange fires before the value lands; hop to the next turn.
            DispatchQueue.main.async {
                LiveSettings.shared.publish(AjarSettings.shared.renderSettings)
                self?.debug.adoptUserSettings()
            }
        }
        // First run, or a machine that cannot currently do the job (no sensor,
        // no Screen Recording): walk through it instead of failing silently.
        if !CommandLine.arguments.contains("--no-onboarding") {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.4) { [self] in onboarding.presentIfNeeded() }
        }
        // The effect is on by default once setup is done, unless the user turned
        // it off — the choice is remembered, so this is the same state they left.
        if AjarSettings.shared.effectEnabled {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.6) { [self] in
                guard onboarding.hasCompletedBefore else { return }
                LiveOverlayController.shared.startIfAllowed(store:store)
            }
        }
        // `--live` starts with the effect already drawn over the built-in
        // display, for when the experiment is the only thing you want to run.
        if CommandLine.arguments.contains("--live") {
            LiveOverlayController.shared.open(store:store)
        }
        // `--debug` opens the control panel straight away, `--settings` the
        // user-facing settings, `--onboard` the setup walkthrough.
        if CommandLine.arguments.contains("--debug") {
            debug.show()
        }
        if CommandLine.arguments.contains("--settings") {
            settingsWindow.show()
        }
        if CommandLine.arguments.contains("--onboard") {
            onboarding.show()
        }
        // `--sweep` drives the manual source with a slow triangle wave, so the
        // whole response can be watched without touching the lid or the sliders.
        if CommandLine.arguments.contains("--sweep") {
            store.usePhysical(false)
            let start = CACurrentMediaTime()
            sweep = Timer.scheduledTimer(withTimeInterval:1.0/30,repeats:true) { [store] _ in
                let phase = (sin((CACurrentMediaTime()-start)*0.3)+1)/2
                store.setManual(90+50*phase)
            }
        }
        menuBar?.refresh()
        NSLog("Ajar menu bar item: %@", menuBar?.diagnostic ?? "not created")
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { [self] in
            NSLog("Ajar menu bar item after 2 s: %@", menuBar?.diagnostic ?? "not created")
        }
    }

    func applicationWillTerminate(_ notification: Notification) { sweep?.invalidate(); store.stop() }

    /// Closing the debug window must not quit: the menu bar item is the app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
