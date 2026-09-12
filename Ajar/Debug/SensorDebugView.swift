import SwiftUI
import AppKit
import QuartzCore

struct SensorDebugView: View {
    let store: HingeStore
    @State private var state = HingeSnapshot()
    @State private var settings = RenderSettings()
    @State private var physical = true
    @State private var manualAngle = 100.0
    @State private var filterMs = 0.0
    @State private var recording = false
    @State private var cpu = 0.0
    @State private var fps = 0.0
    @State private var gpuMs = 0.0
    @State private var ageMs = 0.0
    @State private var motionFrame = MotionFrame()
    @State private var preview = FullscreenPreviewController()
    @State private var previewOpen = false
    @ObservedObject private var overlay = LiveOverlayController.shared
    private let refresh = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Ajar").font(.system(size:28,weight:.semibold))
                    Text("Move gently. Pause. Let it refocus.").foregroundStyle(.secondary)
                    Picker("Input", selection: $physical) {
                        Text("Physical").tag(true); Text("Manual").tag(false)
                    }.pickerStyle(.segmented).onChange(of: physical) { _, value in settings.responseReset += 1; store.usePhysical(value); if !value { store.setManual(manualAngle) } }
                    Text(state.status).font(.caption).foregroundStyle(state.sample == nil ? .orange : .secondary).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
                        row("Raw angle", state.sample.map { String(format:"%.2f°",$0.rawAngle) } ?? "—")
                        if settings.mode == .motion {
                            row("Display angle", String(format:"%.2f°",motionFrame.displayAngle))
                            row("Settled angle", String(format:"%.2f°",motionFrame.anchorAngle))
                            row("Delta / blur", String(format:"%+.2f° / %.0f%%",motionFrame.signedDelta,motionFrame.blur*100))
                        } else {
                            row("Filtered angle", state.sample.map { String(format:"%.2f°",$0.filteredAngle) } ?? "—")
                            row("Velocity", state.sample.map { String(format:"%+.1f °/s",$0.angularVelocity) } ?? "—")
                            row("Progress", state.sample.map { String(format:"%.3f",progress(angle:$0.filteredAngle,minAngle:settings.minAngle,maxAngle:settings.maxAngle)) } ?? "—")
                        }
                        row("Sampling / reads", String(format:"%.1f Hz",state.readHz))
                        row("Changed reports", String(format:"%.1f /s",state.changeHz))
                        row("Last read", String(format:"%.2f ms",state.readMilliseconds))
                        row("Read failures", "\(state.failures)")
                        row("Render / CPU", String(format:"%.0f FPS / %.1f%%",fps,cpu))
                        row("Age / GPU", String(format:"%.1f / %.2f ms",ageMs,gpuMs))
                        row("Overlay live", overlay.isOpen ? String(format:"%.0f FPS / %.2f ms / cap %.0f Hz",PerformanceMetrics.shared.liveFps,PerformanceMetrics.shared.liveGpuMs,overlay.capture.framesPerSecond) : "off")
                        row("Capture", overlay.isOpen ? overlay.status.text + (overlay.status.isRunning && !overlay.capture.isExcludingOwnWindows ? " · waiting for the window server" : "") : "off")
                    }.font(.system(.body,design:.monospaced))
                    if !physical {
                        Text(String(format:"Manual angle %.1f°",manualAngle))
                        Slider(value:$manualAngle,in:30...140).onChange(of:manualAngle) { _, value in store.setManual(value) }
                    }
                    Picker("Preview",selection:$settings.mode) {
                        ForEach(PreviewMode.allCases,id:\.self) { Text($0.rawValue).tag($0) }
                    }
                    Button(previewOpen ? "Close fullscreen preview (esc)" : "Preview fullscreen on built-in display") {
                        preview.toggle(store:store)
                        previewOpen = preview.isOpen
                    }
                    if settings.mode == .motion {
                        MotionControls(settings:$settings.motion)
                        Button("Refocus here") { settings.responseReset += 1 }
                    } else if settings.mode != .tracking { EffectControls(settings:$settings.effect) }
                    Divider()
                    Text("Live screen overlay").font(.headline)
                    Button(overlay.isOpen ? "Remove live overlay (esc)" : "Apply effect to the built-in display") {
                        if !overlay.isOpen && !LiveScreenCapture.hasPermission { LiveScreenCapture.requestPermission() }
                        // The stock fullscreen preview would sit on top of the overlay.
                        if !overlay.isOpen, preview.isOpen { preview.close(); previewOpen = false }
                        overlay.toggle(store:store)
                    }
                    Text(overlay.isOpen ? overlay.status.text : "Draws the effect over the real screen instead of a test image. The control panel floats above it and the overlay is click-through, so the Mac stays usable underneath. Escape removes it.")
                        .font(.caption).foregroundStyle(overlay.isOpen && overlay.status.isRunning ? Color.secondary : Color.orange)
                    if overlay.isOpen && !overlay.status.isRunning {
                        HStack {
                            Button("Request access") {
                                LiveScreenCapture.requestPermission()
                                if LiveScreenCapture.hasPermission { overlay.close(); overlay.open(store:store) }
                            }
                            Button("Open Settings") { LiveScreenCapture.openPermissionSettings() }
                        }
                    }
                    if settings.mode != .motion {
                    Divider()
                    Text("Calibration").font(.headline)
                    HStack {
                        Text("Min °"); TextField("Min",value:$settings.minAngle,format:.number).frame(width:65)
                        Text("Max °"); TextField("Max",value:$settings.maxAngle,format:.number).frame(width:65)
                    }
                    if settings.maxAngle <= settings.minAngle { Text("Max must exceed min. Progress held at zero.").foregroundStyle(.orange) }
                    HStack {
                        Button("Set min here") { if let sample = state.sample { settings.minAngle = sample.rawAngle } }
                        Button("Set max here") { if let sample = state.sample { settings.maxAngle = sample.rawAngle } }
                    }.disabled(state.sample == nil)
                    Text(state.observedMin.isFinite ? String(format:"Observed %.0f° … %.0f°",state.observedMin,state.observedMax) : "Observed range: waiting").font(.caption)
                    Text("70–120° is a starting range, not measured travel limits. Capture two comfortable positions.").font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    Text(String(format:"Low-pass τ: %.0f ms%@",filterMs,filterMs == 0 ? " · OFF" : ""))
                    Slider(value:$filterMs,in:0...40,step:1).onChange(of:filterMs) { _, value in store.setFilter(value) }
                    Text(settings.mode == .motion ? "Not used in Motion / settle — smoothing happens per display frame instead, so whole-degree sensor steps do not jump." : "Off gives frame = F(angle). Filtering adds slight settling; there is no animation interpolation.").font(.caption).foregroundStyle(.secondary)
                    Button(recording ? "Stop CSV recording" : "Record raw / filtered CSV…") {
                        if recording { store.setLogging(nil); recording = false }
                        else {
                            let panel = NSSavePanel(); panel.nameFieldStringValue = "hinge-samples.csv"
                            if panel.runModal() == .OK, let url = panel.url { store.setLogging(url); recording = true }
                        }
                    }
                    Text(state.logStatus).font(.caption).textSelection(.enabled)
                }.padding(24)
            }.frame(width:365)
            Group {
                if settings.mode == .metal || settings.mode == .motion {
                    VStack(alignment:.leading,spacing:18) {
                        Text(settings.mode == .motion ? "MOTION → DEPTH → FOCUS" : "ANGLE SCRUB / ORIGINAL").font(.system(.caption,design:.monospaced)).foregroundStyle(.secondary)
                        MetalTransitionView(store:store,settings:settings)
                            .aspectRatio(CGFloat(SurfaceTextures.aspect),contentMode:.fit)
                        Text(settings.mode == .motion ? "Whole-screen depth blur · move the lid to defocus · hold still and the image catches up"
                                                      : "Original absolute-angle scrub, kept for comparison")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
                        .background(Color(white:0.065))
                        .overlay(alignment:.topLeading) {
                            if state.sample == nil || (state.sample.map { CACurrentMediaTime()-$0.timestamp > 0.25 } ?? true) {
                                Text("STALE / NO INPUT — reconnect or select Manual").padding(12).background(.black.opacity(0.75)).foregroundStyle(.orange)
                            }
                        }
                } else { TransitionView(store:store,settings:settings) }
            }.frame(minWidth:560,minHeight:470)
        }
        .frame(minWidth:925,minHeight:730)
        .onReceive(refresh) { _ in
            state = store.snapshot()
            PerformanceMetrics.shared.refresh()
            cpu = PerformanceMetrics.shared.cpu; fps = PerformanceMetrics.shared.fps
            gpuMs = (settings.mode == .metal || settings.mode == .motion) ? PerformanceMetrics.shared.gpuMs : 0
            ageMs = PerformanceMetrics.shared.sampleAgeMs
            motionFrame = PerformanceMetrics.shared.motionFrame
            // Keep the fullscreen preview in step with the control panel.
            LiveSettings.shared.publish(settings)
            // Escape closes the preview out from under the button, so the label
            // follows the controller rather than the last click.
            previewOpen = preview.isOpen
        }
        .onAppear {
            physical = !store.isManualInput()
            overlay.refreshWindowLevels()
            AjarSettings.shared.apply(to:&settings)
        }
        .onReceive(NotificationCenter.default.publisher(for:.adoptUserSettings)) { _ in
            AjarSettings.shared.apply(to:&settings)
            settings.responseReset += 1
        }
        .onChange(of: overlay.isOpen) { _, _ in overlay.refreshWindowLevels() }
        .transaction { $0.animation = nil }
    }
    func row(_ name: String, _ value: String) -> some View { GridRow { Text(name).foregroundStyle(.secondary); Text(value) } }
}
