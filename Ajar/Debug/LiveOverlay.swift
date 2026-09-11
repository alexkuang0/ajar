import AppKit
import SwiftUI

extension NSScreen {
    var hingeDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }
    var isBuiltIn: Bool { hingeDisplayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false }
}

struct LiveOverlayRoot: View {
    let store: HingeStore
    let capture: LiveScreenCapture
    @ObservedObject var live = LiveSettings.shared
    var body: some View {
        LiveTransitionView(store:store,capture:capture,settings:live.settings)
            .background(Color.clear)
            .ignoresSafeArea()
    }
}

/// The live overlay window: the whole built-in panel, drawn by Metal, sitting
/// just above ordinary windows and just below the control panel.
///
/// It is click-through and never becomes key, so the Mac underneath stays usable
/// while the effect is on. Escape closes it; the monitor is needed because an
/// ignored-mouse, non-key window never gets the key event itself.
final class LiveOverlayController: ObservableObject {
    /// One controller for the process: the control panel drives it, and a
    /// command-line launch can open it before any window appears.
    static let shared = LiveOverlayController()
    @Published private(set) var isOpen = false
    /// Set when the overlay was asked for and could not be shown, so the menu can
    /// say so instead of doing nothing.
    @Published private(set) var blockedReason: String?
    @Published private(set) var status = LiveScreenCapture.State.idle
    let capture = LiveScreenCapture()
    private var window: NSWindow?
    private var escapeMonitor: Any?
    private var originalLevels: [ObjectIdentifier: (window: NSWindow, level: NSWindow.Level)] = [:]

    private init() {
        capture.onState = { [weak self] state in
            guard let self, state != self.status else { return }
            self.status = state
        }
    }

    func toggle(store: HingeStore) { isOpen ? close() : open(store:store) }

    /// Opens the overlay if everything it needs is in place. Used when the
    /// walkthrough finishes and at launch, so "the effect is on by default"
    /// means the same thing in both places.
    @discardableResult
    func startIfAllowed(store: HingeStore) -> Bool {
        var conditions = EffectPolicy.current
        conditions.setupComplete = OnboardingWindowController.shared?.hasCompletedBefore ?? false
        guard EffectPolicy.canEnable(conditions) else {
            blockedReason = EffectPolicy.reasonBlocked(conditions)
            return false
        }
        open(store:store)
        return isOpen
    }

    func open(store: HingeStore) {
        // Strictly the laptop's own panel, and only while it is actually in use:
        // falling back to whatever screen is handy would draw the effect over an
        // external monitor, where it means nothing and where the capture would be
        // of the wrong display. This is the single choke point every caller goes
        // through, including the scripted `--live` start.
        guard !isOpen, HingeCapability.builtInDisplayInUse,
              let screen = HingeCapability.builtInScreen, let displayID = screen.hingeDisplayID else {
            blockedReason = "The built-in display is not in use."
            return
        }
        blockedReason = nil
        let window = NSWindow(contentRect:screen.frame,styleMask:[.borderless],
                              backing:.buffered,defer:false,screen:screen)
        // Above the Dock (20) and the menu bar (24): those are windows too, and
        // at a lower level they punched through the effect as sharp, upright,
        // unmoved strips. They are part of the picture, so they must be captured
        // and transformed like everything else on the screen.
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.isMovable = false
        window.contentView = NSHostingView(rootView:LiveOverlayRoot(store:store,capture:capture))
        window.setFrame(screen.frame,display:true)
        window.orderFront(nil)
        self.window = window
        isOpen = true
        refreshWindowLevels()
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.close()
            return nil
        }
        capture.start(displayID:displayID,overlayWindow:CGWindowID(window.windowNumber))
    }

    func close() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        capture.stop()
        restorePanelLevels()
        window?.orderOut(nil)
        window = nil
        isOpen = false
        status = .idle
    }

    /// The control panel stays on top of the overlay, otherwise it would be
    /// covered by the very effect it is driving. The panel calls this again when
    /// it appears, because under `--live` the overlay opens before it exists.
    func refreshWindowLevels() {
        guard isOpen, let overlay = window else { return }
        let raised = NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+1)
        for window in NSApp.windows where window !== overlay && window.level != raised {
            if originalLevels[ObjectIdentifier(window)] == nil {
                originalLevels[ObjectIdentifier(window)] = (window,window.level)
            }
            window.level = raised
        }
    }

    private func restorePanelLevels() {
        for (_, entry) in originalLevels { entry.window.level = entry.level }
        originalLevels = [:]
    }
}
