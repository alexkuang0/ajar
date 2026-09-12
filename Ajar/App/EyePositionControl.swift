import SwiftUI

/// "Detect where I'm sitting": one button, one camera sample, and the result
/// lands on the camera the user can still drag afterwards.
struct EyePositionControl: View {
    /// The lid angle at the moment of detection: the camera measures the eye in
    /// the screen's frame, and converting that to a room position needs to know
    /// which way the screen was facing.
    let lidAngle: Double
    @ObservedObject private var settings = AjarSettings.shared
    @State private var phase = Phase.idle

    private enum Phase: Equatable {
        case idle
        case working
        case done(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            HStack(spacing:10) {
                Button {
                    Task { await detect() }
                } label: {
                    HStack(spacing:6) {
                        if phase == .working { ProgressView().controlSize(.small) }
                        Text(phase == .working ? "Looking…" : "Detect where I'm sitting")
                    }
                }
                .disabled(phase == .working)
                Text(String(format:"now %.0f cm back, %.0f cm up",
                            settings.eyeDistance*panelHeight/10,
                            settings.eyeHeight*panelHeight/10))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            switch phase {
            case .idle:
                Text("Samples the built-in camera for about a second, finds your eyes, and moves the camera to match. The camera light blinks; nothing is recorded or sent. Your interpupillary distance is assumed to be 63 mm and the lens about 70°, so treat the result as a good starting point and drag it if it feels off.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            case .working:
                Text("Hold still and look at the screen.").font(.caption).foregroundStyle(.secondary)
            case .done(let message):
                Text(message).font(.caption).foregroundStyle(.green).fixedSize(horizontal:false,vertical:true)
            case .failed(let message):
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal:false,vertical:true)
            }
        }
    }

    private var panelHeight: Double { EyeDetector.assumptions.panelHeightMillimetres }

    private func detect() async {
        phase = .working
        let preview = EyePreviewWindowController.shared
        preview.begin()
        do {
            let estimate = try await EyeDetector.shared.detect { frame in preview.show(frame) }
            // estimate is in the screen's frame at this angle; the settings are
            // in the room's frame, so rotate it back.
            let room = CameraRig.worldPosition(height:estimate.cameraHeight,
                                               distance:estimate.viewDistance,
                                               lidAngle:lidAngle)
            settings.eyeDistance = room.x
            settings.eyeHeight = room.y
            let confidence = estimate.confidence > 0.6 ? "" : " (rough — check it against the rig)"
            preview.finish(.found(estimate.note + confidence))
            phase = .done(estimate.note + confidence)
        } catch {
            preview.finish(.failed(error.localizedDescription))
            phase = .failed(error.localizedDescription)
        }
    }
}
