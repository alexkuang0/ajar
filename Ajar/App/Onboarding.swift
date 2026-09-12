import AppKit
import AVFoundation
import SwiftUI

/// What Ajar needs, on one page.
///
/// This used to be a four-step walkthrough. It is a checklist because the four
/// things are independent: two of them are permissions the user grants in System
/// Settings, one is a fact about the machine, and one is optional. A step-by-step
/// flow implied an order that does not exist, and put the buttons where a tall
/// step could hide them.
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static var shared: OnboardingWindowController?
    private let store: HingeStore
    private let defaults: UserDefaults
    private var window: NSWindow?
    private static let completionKey = "dev.kuang.ajar.onboarded"

    init(store: HingeStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        super.init()
    }

    /// What the menu bar gate reads. A machine that has not been through this
    /// should not be able to switch the effect on and find it does nothing.
    var hasCompletedBefore: Bool { defaults.bool(forKey:Self.completionKey) }

    /// True when everything the effect needs is in place. The camera is not part
    /// of this: it only fills in where you sit, and the dot can be dragged.
    var isReady: Bool {
        let sensorWorks = store.snapshot().sample != nil || HingeCapability.probe().isReadable
        return sensorWorks && HingeCapability.hasScreenCapturePermission && HingeCapability.builtInDisplayInUse
    }

    func presentIfNeeded() {
        guard !hasCompletedBefore || !isReady else { return }
        show()
    }

    func show() {
        if window == nil {
            let root = OnboardingView(store:store,finish:{ [weak self] in self?.finish() })
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:620,height:560),
                                  styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = "Ajar Setup"
            window.contentView = NSHostingView(rootView:root)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps:true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish() {
        defaults.set(true,forKey:Self.completionKey)
        window?.orderOut(nil)
        AjarSettings.shared.effectEnabled = true
        UserNotifier.shared.prepare()
        LiveOverlayController.shared.startIfAllowed(store:store)
    }
}

struct OnboardingView: View {
    let store: HingeStore
    var finish: () -> Void
    @State private var sample: HingeSample?
    @State private var hasPermission = HingeCapability.hasScreenCapturePermission
    @State private var displayInUse = HingeCapability.builtInDisplayInUse
    @State private var cameraWorks = false
    @State private var sensorWorks = false
    private let tick = Timer.publish(every:1,on:.main,in:.common).autoconnect()

    private var ready: Bool { sensorWorks && hasPermission && displayInUse }

    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            VStack(alignment:.leading,spacing:8) {
                HStack(spacing:10) {
                    Image(systemName:"laptopcomputer").font(.system(size:22))
                    Text("Ajar needs three things").font(.system(size:24,weight:.semibold))
                }
                Text("Two of them are permissions macOS asks for, one is a fact about this Mac. The camera is optional.")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal,28).padding(.top,24).padding(.bottom,16)

            ScrollView {
                VStack(alignment:.leading,spacing:12) {
                    row(ok:sensorWorks,
                        title:"Lid angle sensor",
                        detail:sensorDetail,
                        action:sensorWorks ? nil : ("Check again", { refresh(probeSensor:true) }))
                    row(ok:displayInUse,
                        title:"Built-in display in use",
                        detail:HingeCapability.displayDescription)
                    row(ok:hasPermission,
                        title:"Screen Recording",
                        detail:hasPermission ? "Granted. Ajar reads the screen to draw the effect over it; nothing leaves the Mac."
                                             : "Needed to draw the effect over your screen. macOS only applies it to a fresh launch.",
                        action:hasPermission ? ("Quit and reopen Ajar", { relaunch() })
                                             : ("Open Screen Recording settings", { askForPermission() }))
                    row(ok:cameraWorks,
                        title:"Camera (optional)",
                        detail:cameraWorks ? "Ajar can estimate where your eyes are, so the camera lands in the right place by itself. It samples once, when asked, and never records."
                                           : "Without it you can still drag the camera into place by hand.",
                        action:("Open camera settings…", { SettingsWindowController.shared?.show() }),
                        optional:true)
                }
                .padding(.horizontal,28)
                .padding(.bottom,16)
            }

            Divider()
            HStack {
                Button("Position the camera…") { SettingsWindowController.shared?.show() }
                Spacer()
                Button(ready ? "Start using Ajar" : "Finish the items above") { finish() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
            .padding(.horizontal,28).padding(.vertical,16)
        }
        .frame(minWidth:620,minHeight:560,alignment:.topLeading)
        .onReceive(tick) { _ in refresh(probeSensor:false) }
        .onAppear { refresh(probeSensor:true) }
    }

    private var sensorDetail: String {
        // `summary` already reports the live reading when the sensor answers.
        return HingeCapability.summary
    }

    private func row(ok: Bool, title: String, detail: String,
                     action: (String, () -> Void)? = nil, optional: Bool = false) -> some View {
        HStack(alignment:.top,spacing:12) {
            Image(systemName: ok ? "checkmark.circle.fill" : (optional ? "circle.dashed" : "exclamationmark.circle.fill"))
                .font(.system(size:16))
                .foregroundStyle(ok ? Color.green : (optional ? Color.secondary : Color.orange))
                .padding(.top,2)
            VStack(alignment:.leading,spacing:4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if let action {
                    Button(action.0) { action.1() }.controlSize(.small)
                }
            }
            Spacer(minLength:0)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08),in:RoundedRectangle(cornerRadius:10))
    }

    private func refresh(probeSensor: Bool) {
        sample = store.snapshot().sample
        hasPermission = HingeCapability.hasScreenCapturePermission
        displayInUse = HingeCapability.builtInDisplayInUse
        if probeSensor || sample == nil {
            sensorWorks = store.snapshot().sample != nil || HingeCapability.probe().isReadable
        } else {
            sensorWorks = true
        }
        cameraWorks = cameraIsAvailable()
    }

    private func askForPermission() {
        HingeCapability.requestScreenCapturePermission()
        HingeCapability.openScreenCaptureSettings()
        hasPermission = HingeCapability.hasScreenCapturePermission
    }

    /// A newly granted permission does not apply to a running process.
    private func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at:url,configuration:configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

/// Whether a built-in camera exists at all. Asking for access is the user's move,
/// from the settings window, so this only reports the hardware.
private func cameraIsAvailable() -> Bool {
    let session = AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera],
                                                   mediaType:.video,position:.unspecified)
    return !session.devices.isEmpty
}
