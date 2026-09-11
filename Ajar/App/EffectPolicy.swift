import AppKit

/// Whether the effect is allowed to be on, and why not when it is not.
///
/// Three things have to be true, and each fails in a way that would otherwise
/// look like the app being broken rather than unconfigured: the walkthrough has
/// to be finished, Screen Recording has to be granted, and there has to be a
/// built-in display to draw on. In clamshell mode with an external monitor there
/// is no built-in panel in `NSScreen.screens` at all, so the overlay would have
/// nothing to cover.
enum EffectPolicy {
    struct Conditions: Equatable {
        var setupComplete: Bool
        var hasScreenCapturePermission: Bool
        var builtInDisplayInUse: Bool
    }

    static var current: Conditions {
        Conditions(setupComplete:true,
                   hasScreenCapturePermission:HingeCapability.hasScreenCapturePermission,
                   builtInDisplayInUse:HingeCapability.builtInDisplayInUse)
    }

    static func canEnable(_ conditions: Conditions) -> Bool {
        conditions.setupComplete && conditions.hasScreenCapturePermission && conditions.builtInDisplayInUse
    }

    /// A sentence for the menu bar item, or nil when the effect may run.
    static func reasonBlocked(_ conditions: Conditions) -> String? {
        if !conditions.setupComplete { return "Finish setup to use the effect…" }
        if !conditions.builtInDisplayInUse { return "Built-in display is not in use…" }
        if !conditions.hasScreenCapturePermission { return "Screen Recording permission needed…" }
        return nil
    }
}

extension HingeCapability {
    /// Set from `--assume-no-built-in-display`, so the clamshell path can be
    /// exercised without closing the lid onto an external monitor.
    nonisolated(unsafe) static var ignoreBuiltInDisplay = false

    /// True when the laptop's own panel is among the active screens. A closed
    /// lid with an external monitor attached leaves it out.
    static var builtInDisplayInUse: Bool {
        if ignoreBuiltInDisplay { return false }
        return NSScreen.screens.contains { $0.isBuiltIn }
    }

    /// The built-in screen, or nil when there is not one in use. Used by paths
    /// that must never draw on an external display by accident.
    static var builtInScreen: NSScreen? { NSScreen.screens.first { $0.isBuiltIn } }

    /// One line for the walkthrough.
    static var displayDescription: String {
        guard let screen = builtInScreen, let id = screen.hingeDisplayID else {
            return "The laptop's own display is not in use. Ajar draws on the built-in panel, so open the lid and turn off any clamshell setup."
        }
        let millimetres = CGDisplayScreenSize(id)
        return String(format:"Built-in display in use: %.0f × %.0f mm, %d × %d pixels.",
                      Double(millimetres.width), Double(millimetres.height),
                      Int(CGDisplayPixelsWide(id)), Int(CGDisplayPixelsHigh(id)))
    }
}
