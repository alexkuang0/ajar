import AppKit
import SwiftUI

/// The settings a user is meant to see: where the camera is, how strong the
/// effect is, and nothing else. The lab lives behind Show Debug Window.
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// The walkthrough links here for the camera rig, so it needs the same one.
    static var shared: SettingsWindowController?
    private let store: HingeStore
    private var window: NSWindow?

    init(store: HingeStore) {
        self.store = store
        super.init()
    }

    var isOpen: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let root = SettingsView(lidAngle: { [weak store] in store?.snapshot().sample?.rawAngle ?? 100 })
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:640),
                                  styleMask:[.titled,.closable],backing:.buffered,defer:false)
            window.title = "Ajar Settings"
            window.contentView = NSHostingView(rootView:root)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps:true)
        window?.makeKeyAndOrderFront(nil)
    }

    func toggle() { isOpen ? window?.orderOut(nil) : show() }
}

struct SettingsView: View {
    @ObservedObject private var settings = AjarSettings.shared
    /// Read lazily so the rig picture follows the hinge while the window is open.
    let lidAngle: () -> Double
    @State private var angle = 100.0
    private let tick = Timer.publish(every:0.25,on:.main,in:.common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("Your position").font(.headline)
                EyePositionControl(lidAngle:angle)
                Divider()
                Text("Camera").font(.headline)
                CameraRigRepresentable(settings:binding,lidAngle:angle)
                    .frame(maxWidth:.infinity,minHeight:340,maxHeight:340)
                Text(String(format:"%.2f screen heights in front of the hinge, %.2f above the hinge plane. One grid square is 0.5.",
                            settings.eyeDistance,settings.eyeHeight))
                    .font(.caption).monospacedDigit()
                Text("Drag the viewer on the plane through the screen's vertical midline. That is the only control: the drag moves it in the same two numbers the picture draws, so what you see is where it is. The screen turns; the viewer does not. Where you put it decides how much the picture's height collapses when it tips.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                Text("Effect").font(.headline)
                slider("How quickly the frosting builds (° of travel)",value:$settings.blurSpan,range:5...90)
                slider("Maximum blur σ (px at 1000 px picture height)",value:$settings.maxBlur,range:0...48)
                Text("Neither of these touches the tilt. The picture holds the angle the lid had when it stopped, and only catches up once the lid has been still for a moment — that part is not scaled by anything here.\n\nFrosting builds is how many degrees of lid travel the frosting climbs over. Smaller means it fogs up sooner; the curve is tanh, so every further degree still adds a little more, it just keeps arriving more slowly.\n\nMaximum blur σ is the ceiling of that curve, in pixels measured at a 1000-pixel picture height, so the real blur scales with the size of your display.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Divider()
                HStack {
                    Button("Reset to defaults") { settings.reset() }
                    Spacer()
                    Button("Set Up Ajar Again…") { OnboardingWindowController.shared?.show() }
                }
            }
            .padding(24)
        }
        .frame(minWidth:600,minHeight:640)
        .onReceive(tick) { _ in angle = lidAngle() }
    }

    private var binding: Binding<MotionSettings> {
        Binding(get:{ settings.motion },
                set:{ new in
                    settings.eyeDistance = new.eyeDistance
                    settings.eyeHeight = new.eyeHeight
                    settings.blurSpan = new.blurSpan
                    settings.maxBlur = new.maxBlur
                })
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment:.leading,spacing:3) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue,format:.number.precision(.fractionLength(2))).monospacedDigit()
            }
            Slider(value:value,in:range)
        }
    }
}
