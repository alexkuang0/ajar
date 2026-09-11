import AppKit
import SwiftUI

/// The original control panel, now created on demand.
///
/// It is deliberately not a SwiftUI `Window` scene: a scene would be built at
/// launch, and this app has no window until someone asks for one. Closing it
/// leaves the experiment — and the menu bar item — running.
final class DebugWindowController: NSObject, NSWindowDelegate {
    private let store: HingeStore
    private var window: NSWindow?

    init(store: HingeStore) {
        self.store = store
        super.init()
    }

    var isOpen: Bool { window?.isVisible ?? false }

    /// Lets the settings window change the four user-facing values without the
    /// lab window's own four-per-second publish overwriting them again.
    func adoptUserSettings() {
        NotificationCenter.default.post(name:.adoptUserSettings,object:nil)
    }

    func show() {
        if window == nil {
            let root = SensorDebugView(store:store)
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1060,height:820),
                                  styleMask:[.titled,.closable,.miniaturizable,.resizable],
                                  backing:.buffered,defer:false)
            window.title = "Ajar"
            window.contentView = NSHostingView(rootView:root)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("HingeDebugWindow")
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps:true)
        window?.makeKeyAndOrderFront(nil)
    }

    func toggle() { isOpen ? window?.orderOut(nil) : show() }

    func windowWillClose(_ notification: Notification) {
        // The window is kept so its state survives; the menu bar item is now the
        // only thing on screen, which is the normal way to run this.
    }
}
