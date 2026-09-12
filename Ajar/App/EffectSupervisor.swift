import AppKit
import UserNotifications

/// Watches for the laptop's own display going away and back.
///
/// Closing the lid onto an external monitor — clamshell — removes the built-in
/// panel from the active screens, and the overlay has nothing left to cover: it
/// would be a full-screen effect drawn on a display that is off. So the effect
/// comes down on its own, says why, and comes back when the panel does. The
/// user's choice is remembered throughout; only the running state changes.
final class EffectSupervisor {
    enum Action: Equatable {
        case none
        /// The built-in display went away while the effect was running.
        case disable(notify: Bool)
        /// It came back, and the user wants the effect on.
        case enable
    }

    private let store: HingeStore
    private let overlay: LiveOverlayController
    private let settings: AjarSettings
    private let onboarding: OnboardingWindowController
    private var builtInWasInUse: Bool
    /// Called after the supervisor changes anything, so the menu can refresh.
    var onChange: (() -> Void)?

    init(store: HingeStore, overlay: LiveOverlayController, settings: AjarSettings,
         onboarding: OnboardingWindowController) {
        self.store = store
        self.overlay = overlay
        self.settings = settings
        self.onboarding = onboarding
        self.builtInWasInUse = HingeCapability.builtInDisplayInUse
        NotificationCenter.default.addObserver(self,selector:#selector(displaysChanged),
                                               name:NSApplication.didChangeScreenParametersNotification,
                                               object:nil)
    }

    /// The decision on its own, so the rules can be read and tested without
    /// screens coming and going.
    static func action(builtInInUse: Bool, builtInWasInUse: Bool, overlayRunning: Bool,
                       effectEnabled: Bool, setupComplete: Bool) -> Action {
        guard setupComplete else { return .none }
        if !builtInInUse {
            // Only worth telling someone about if it was actually doing something.
            return overlayRunning ? .disable(notify:builtInWasInUse) : .none
        }
        if !builtInWasInUse, effectEnabled, !overlayRunning { return .enable }
        return .none
    }

    @objc private func displaysChanged() {
        let inUse = HingeCapability.builtInDisplayInUse
        let action = Self.action(builtInInUse:inUse,
                                 builtInWasInUse:builtInWasInUse,
                                 overlayRunning:overlay.isOpen,
                                 effectEnabled:settings.effectEnabled,
                                 setupComplete:onboarding.hasCompletedBefore)
        builtInWasInUse = inUse
        switch action {
        case .none:
            break
        case .disable(let notify):
            overlay.close()
            if notify {
                UserNotifier.shared.post(
                    title:"Effect turned off",
                    body:"The built-in display is no longer in use — the lid is closed or the Mac is in clamshell. Ajar will turn the effect back on when it returns.")
            }
        case .enable:
            overlay.startIfAllowed(store:store)
        }
        onChange?()
    }
}

/// System notifications, with the authorization asked for at the one moment it
/// makes sense: the end of setup, when the user has just been told what Ajar does.
final class UserNotifier {
    static let shared = UserNotifier()
    private var asked = false

    func prepare() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options:[.alert,.sound]) { _, error in
            if let error { NSLog("Ajar: notification permission not granted: %@", error.localizedDescription) }
        }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier:UUID().uuidString,content:content,trigger:nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { NSLog("Ajar: could not post notification: %@", error.localizedDescription) }
        }
    }
}
