import Foundation

// Revision-three interaction experiment. The image reacts to how far the lid has
// travelled since it last settled, not to where the lid is and not to how fast it
// is moving. Moving accumulates the effect; holding still releases it.
enum MotionField: String, CaseIterable { case hinge = "Hinge sweep", gradient = "Depth gradient" }
struct MotionSettings: Equatable {
    var smoothingMs = 65.0
    var settleSeconds = 2.2
    /// Angular scale of the frosting only: the travel at which the blur reaches
    /// about three quarters of its strength. It does not touch the geometry.
    ///
    /// Not a limit either — `tanh(delta / blurSpan)` keeps changing for every
    /// further degree, just more slowly. The tilt is not on this curve at all:
    /// it is the real angle travelled (see `MotionResponse.frame`).
    var blurSpan = 30.0
    var maxBlur = 20.0
    var stillDelay = 0.25
    // The lid keeps wobbling for a moment after you let go. An excursion below
    // this, measured over `motionWindow`, counts as stillness rather than
    // movement, so wobble neither starts the effect nor delays the catch-up.
    var wobbleDeadband = 1.0
    var motionWindow = 0.5
    var softness = 0.45
    var curvature = 0.08
    var reversed = false
    var field = MotionField.gradient
    var debugMask = false
    var reverseRotation = false
    /// Where the viewer sits, in the room rather than on the screen: how far in
    /// front of the hinge (along the deck) and how far above the hinge plane,
    /// both in screen heights.
    ///
    /// Storing it this way is what keeps the camera still when the lid moves.
    /// A person does not rotate with the screen, so the numbers must not be
    /// expressed in the screen's frame; the renderer converts to that frame at
    /// the current lid angle every frame (`CameraRig.panelCoordinates`), which is
    /// also the physically honest thing to do.
    var eyeDistance = 2.4
    var eyeHeight = 2.2

    /// The eye expressed in the screen's own frame, which is what the projection
    /// needs: height along the panel from the hinge, and perpendicular distance
    /// in front of it. Both change as the lid turns, even though the eye does not.
    func panelCamera(atLidAngle lidAngle: Double) -> (height: Double, distance: Double) {
        let panel = CameraRig.panelCoordinates(x:eyeDistance,y:eyeHeight,lidAngle:lidAngle)
        return (height:panel.height,distance:panel.distance)
    }
    // Live overlay only. The overlay window sits above the real screen, so it
    // stays transparent until there is enough effect to be worth covering the
    // real screen for; these are mask values (0 = none, 1 = maximum effect).
    // The band is deliberately narrow: a wide one leaves the unmoved screen
    // visible through the lower half of the picture, which reads as a bug.
    var overlayFadeStart = 0.0
    var overlayFadeEnd = 0.04
}
struct MotionFrame {
    /// Where the plane is edge-on to the camera: at 90° the projection has no
    /// meaning, so the tilt is held just under it.
    static let maximumTilt = 89.0
    var displayAngle = 0.0
    var anchorAngle = 0.0
    var signedDelta = 0.0
    /// Normalised tilt, `signedDelta / maximumTilt`, which is what the
    /// projection uniforms take.
    var ratio = 0.0
    var blur = 0.0
}
struct MotionResponse {
    private var previousTime: Double?
    private var displayAngle = 0.0
    private var anchorAngle = 0.0
    private var stillTime = 0.0
    private var history: [(time: Double, angle: Double)] = []
    mutating func reset() { previousTime = nil; stillTime = 0; history.removeAll() }
    mutating func update(angle: Double, timestamp: Double, settings: MotionSettings) -> MotionFrame {
        guard angle.isFinite, timestamp.isFinite else { return frame(settings:settings) }
        guard let previousTime, timestamp > previousTime, timestamp-previousTime < 0.5 else {
            // First sample, or a gap: re-anchor so a reconnect does not read as
            // a large lid movement.
            self.previousTime = timestamp
            displayAngle = angle; anchorAngle = angle; stillTime = 0
            history = [(timestamp,angle)]
            return frame(settings:settings)
        }
        let dt = timestamp-previousTime
        self.previousTime = timestamp
        let fastTau = max(0.001,settings.smoothingMs/1000)
        let previousDisplay = displayAngle
        // Closed-form first-order step: interpolates whole-degree reports across
        // display frames and stays identical at 30/60/120 Hz.
        displayAngle = angle + (previousDisplay-angle)*exp(-dt/fastTau)

        // Movement gate. While the lid is really moving the reference stays put,
        // so the excursion accumulates and the effect keeps growing with the
        // angle. Only once the lid is quiet does the image start catching up.
        // Judging movement by recent excursion rather than instantaneous speed
        // is what lets the hinge's residual wobble read as stillness.
        history.append((timestamp,displayAngle))
        let window = max(0.05,settings.motionWindow)
        while let first = history.first, timestamp-first.time > window { history.removeFirst() }
        let excursion = (history.map(\.angle).max() ?? displayAngle)-(history.map(\.angle).min() ?? displayAngle)
        if excursion > settings.wobbleDeadband { stillTime = 0 } else { stillTime += dt }
        if stillTime >= settings.stillDelay {
            let slowTau = max(0.05,settings.settleSeconds/4.6) // ~99% after this many seconds.
            anchorAngle += (displayAngle-anchorAngle)*(1-exp(-dt/slowTau))
        }
        return frame(settings:settings)
    }
    private func frame(settings: MotionSettings) -> MotionFrame {
        let delta = displayAngle-anchorAngle
        // The tilt is the real thing: the picture stays where it was when the
        // effect started, and the display has rotated away from it by exactly
        // the angle travelled since. Move the lid 50° and the picture sits at
        // 50° until the catch-up pulls the two back together. 89° is not a
        // taste limit but the point where the plane is edge-on to the camera and
        // the projection stops meaning anything.
        let tilt = min(max(delta,-MotionFrame.maximumTilt),MotionFrame.maximumTilt)
        let ratio = tilt/MotionFrame.maximumTilt
        // Frosting is a rendering choice rather than a geometric quantity, so it
        // keeps its own soft curve; tanh never arrives, so more travel always
        // keeps changing it.
        let blur = tanh(abs(delta)/max(2,settings.blurSpan))
        return MotionFrame(displayAngle:displayAngle,anchorAngle:anchorAngle,
                           signedDelta:delta,ratio:ratio,blur:blur)
    }
}

func motionMask(x: Double, y: Double, frame: MotionFrame, settings: MotionSettings) -> Double {
    // x and y are picture coordinates: y = 1 is the hinge line, y = 0 the free
    // edge. The hinge sits on the rotation axis so it stays comparatively sharp;
    // the free edge is furthest from the original plane and reads as frosted.
    let fromHinge = 1-y
    let distance = settings.reversed ? 1-fromHinge : fromHinge
    if settings.field == .gradient { return frame.blur*(0.15+0.85*distance) }
    let softness = settings.softness
    let front = -softness + (1+2*softness)*frame.blur
    let curve = settings.curvature*pow(x-0.5,2)
    let region = 1-smoothstep(front-softness,front+softness,distance+curve)
    return frame.blur*(0.15+0.85*region)
}

/// Steps the motion model on the display clock, from the latest sensor sample.
///
/// The model advances on the sensor timestamp, not per drawn frame: several
/// display frames can reference one whole-degree report, and re-running the
/// follower for the same timestamp would double-count it. The preview window and
/// the live overlay both run through this, so they respond identically.
struct MotionDriver {
    struct Token: Equatable {
        var reset: Int
        var mode: PreviewMode?
    }
    private var response = MotionResponse()
    private var currentFrame = MotionFrame()
    private var lastSampleTime: Double?
    private var appliedToken: Token?

    mutating func frame(sample: HingeSample?, settings: MotionSettings, token: Token) -> MotionFrame {
        if appliedToken != token {
            appliedToken = token
            response.reset()
            lastSampleTime = nil
            currentFrame = MotionFrame()
        }
        guard let sample else {
            response.reset()
            lastSampleTime = nil
            currentFrame = MotionFrame()
            return currentFrame
        }
        if let previous = lastSampleTime, sample.timestamp > previous {
            // A gap means the lid was closed or the sensor stalled; re-anchor
            // rather than reading the gap as a large movement.
            if sample.timestamp - previous > 0.5 { response.reset() }
            lastSampleTime = sample.timestamp
            currentFrame = response.update(angle: sample.rawAngle, timestamp: sample.timestamp, settings: settings)
        } else if lastSampleTime == nil || sample.timestamp < (lastSampleTime ?? 0) {
            lastSampleTime = sample.timestamp
            response.reset()
            currentFrame = response.update(angle: sample.rawAngle, timestamp: sample.timestamp, settings: settings)
        }
        return currentFrame
    }
}
