import AppKit
import SwiftUI

/// The control panel owns the settings; the preview mirrors the last published
/// value, so both windows show the same effect without a shared mutation path.
final class LiveSettings: ObservableObject {
    static let shared = LiveSettings()
    @Published var settings = RenderSettings()
    private init() {}
    func publish(_ value: RenderSettings) {
        if settings != value { settings = value }
    }
}

struct FullscreenPreviewRoot: View {
    let store: HingeStore
    @ObservedObject var live = LiveSettings.shared
    var body: some View {
        MetalTransitionView(store:store,settings:live.settings)
            .background(Color.black)
            .ignoresSafeArea()
    }
}

/// A borderless window covering the built-in display. Escape closes it.
/// Borderless windows refuse key status by default, which would leave Escape
/// unhandled, so key handling is enabled explicitly here.
final class PreviewWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?(); return }
        super.keyDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

final class FullscreenPreviewController {
    private var window: NSWindow?
    private var escapeMonitor: Any?
    private(set) var isOpen = false

    func toggle(store: HingeStore) { isOpen ? close() : open(store:store) }

    func open(store: HingeStore) {
        guard !isOpen, let screen = Self.builtInScreen() else { return }
        let window = PreviewWindow(contentRect:screen.frame,styleMask:[.borderless],
                                   backing:.buffered,defer:false,screen:screen)
        window.onEscape = { [weak self] in self?.close() }
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: FullscreenPreviewRoot(store:store))
        window.setFrame(screen.frame,display:true)
        window.makeKeyAndOrderFront(nil)
        self.window = window
        isOpen = true
        NSApp.activate(ignoringOtherApps:true)
        NSApp.presentationOptions = [.autoHideDock,.autoHideMenuBar]
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.close()
            return nil
        }
    }

    func close() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        NSApp.presentationOptions = []
        window?.orderOut(nil)
        window = nil
        isOpen = false
    }

    /// The laptop's own panel, so the preview never lands on an external monitor.
    static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        } ?? NSScreen.main
    }
}
