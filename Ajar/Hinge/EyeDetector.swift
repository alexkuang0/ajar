import AVFoundation
import AppKit
import CoreImage
import CoreGraphics
import Vision

/// One frame of what the camera saw, and what was found in it.
///
/// This exists for the preview window: the button samples the camera for about
/// a second and then moves a dot somewhere, which is a black box unless the user
/// can see the picture the measurement came from and the two points it was read
/// from.
struct EyeFrame {
    let image: CGImage
    /// Pupil centres in image pixels, y down — the same convention the detector
    /// measures in, so nothing has to be flipped on the way to the screen.
    let pupils: [CGPoint]
    let size: CGSize
    /// Whether this frame passed the pose gate and counts towards the average.
    let usable: Bool
}

/// Samples the built-in camera for about a second, finds the eyes in each frame
/// with Vision, and turns them into a camera position.
///
/// Deliberately a one-shot: it runs only when the user asks for it, stops as
/// soon as it has enough frames, and never keeps the camera open. That is easier
/// to trust than a live feed, and the green light blinks rather than glows.
final class EyeDetector: NSObject {
    enum Failure: LocalizedError {
        case noCamera
        case denied
        case busy

        var errorDescription: String? {
            switch self {
            case .noCamera: return "No built-in camera found."
            case .denied: return "Camera access is off for Ajar. Turn it on in System Settings → Privacy & Security → Camera."
            case .busy: return "A camera check is already running."
            }
        }
    }

    static let shared = EyeDetector()

    private let session = AVCaptureSession()
    private let lock = NSLock()
    private var detections: [EyeDetection] = []
    private var seen = 0
    private var running = false
    private let queue = DispatchQueue(label:"ajar.eyedetect",qos:.userInitiated)
    private var onFrame: ((EyeFrame) -> Void)?
    private var lastPreview = 0.0
    private lazy var imageContext = CIContext(options:[.cacheIntermediates:false])

    /// Panel size and camera height come from the machine, not from a table.
    static var assumptions: EyePositionEstimator.Assumptions {
        var assumptions = EyePositionEstimator.Assumptions()
        if let screen = NSScreen.screens.first(where: { $0.isBuiltIn }),
           let number = screen.hingeDisplayID {
            let millimetres = CGDisplayScreenSize(number)
            if millimetres.height > 50 { assumptions.panelHeightMillimetres = Double(millimetres.height) }
        }
        return assumptions
    }

    /// `onFrame`, when given, is called on the main queue with each analysed
    /// frame while the run lasts — the preview window, not the estimator, is its
    /// only consumer.
    func detect(onFrame: ((EyeFrame) -> Void)? = nil) async throws -> EyePositionEstimator.Estimate {
        guard beginRun() else { throw Failure.busy }
        setObserver(onFrame)
        defer { setObserver(nil); endRun() }

        switch AVCaptureDevice.authorizationStatus(for:.video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for:.video) else { throw Failure.denied }
        default:
            throw Failure.denied
        }

        resetSamples()
        try await collectFrames()

        let captured = samples()
        _ = captured.count
        let assumptions = Self.assumptions
        switch EyePositionEstimator.estimate(from:captured,assumptions:assumptions) {
        case .success(let estimate): return estimate
        case .failure(let error): throw error
        }
    }

    private func collectFrames() async throws {
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera],
                                                         mediaType:.video,position:.unspecified)
        guard let device = discovery.devices.first(where: { $0.isConnected }) else { throw Failure.noCamera }
        // The default format is 640x480; 720p halves the landmark noise.
        if let format = device.formats.first(where: { CMVideoFormatDescriptionGetDimensions($0.formatDescription).width == 1280 })
            ?? device.formats.last {
            try? device.lockForConfiguration()
            device.activeFormat = format
            device.unlockForConfiguration()
        }

        session.beginConfiguration()
        session.sessionPreset = .high
        if let input = try? AVCaptureDeviceInput(device:device), session.canAddInput(input) {
            session.addInput(input)
        } else {
            session.commitConfiguration()
            throw Failure.noCamera
        }
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self,queue:queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        session.startRunning()
        // About thirty frames at 30 Hz: long enough to average, short enough that
        // the light is barely on.
        try? await Task.sleep(nanoseconds:1_100_000_000)
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)
        session.commitConfiguration()
    }

    private func beginRun() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if running { return false }
        running = true
        return true
    }

    private func endRun() {
        lock.lock(); defer { lock.unlock() }
        running = false
    }

    private func resetSamples() {
        lock.lock(); defer { lock.unlock() }
        detections = []
        seen = 0
    }

    private func samples() -> [EyeDetection] {
        lock.lock(); defer { lock.unlock() }
        return detections
    }

    private func countSamples() -> Int {
        lock.lock(); defer { lock.unlock() }
        return detections.count
    }

    private func noteSeen() {
        lock.lock(); defer { lock.unlock() }
        seen += 1
    }

    private func add(_ detection: EyeDetection) {
        lock.lock(); defer { lock.unlock() }
        detections.append(detection)
    }

    private func setObserver(_ observer: ((EyeFrame) -> Void)?) {
        lock.lock(); defer { lock.unlock() }
        onFrame = observer
    }

    private func observer() -> ((EyeFrame) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return onFrame
    }

    private func analyse(_ buffer: CVPixelBuffer) {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer:buffer,orientation:.up,options:[:])
        try? handler.perform([request])
        noteSeen()
        guard let face = (request.results ?? []).first,
              let landmarks = face.landmarks,
              let left = landmarks.leftPupil, let right = landmarks.rightPupil,
              left.pointCount > 0, right.pointCount > 0 else {
            publish(buffer,pupils:[],usable:false)
            return
        }

        let size = CGSize(width:CVPixelBufferGetWidth(buffer),height:CVPixelBufferGetHeight(buffer))
        // Vision normalises landmarks to the face box, and the face box to the
        // image; both have their origin at the bottom left.
        func imagePoint(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let point = region.normalizedPoints[0]
            let normalised = CGPoint(x:face.boundingBox.minX + CGFloat(point.x)*face.boundingBox.width,
                                     y:face.boundingBox.minY + CGFloat(point.y)*face.boundingBox.height)
            return CGPoint(x:normalised.x*size.width,y:(1-normalised.y)*size.height)
        }
        let detection = EyeDetection(leftPupil:imagePoint(left),rightPupil:imagePoint(right),
                                     imageSize:size,
                                     yaw:Double(face.yaw?.doubleValue ?? 0),
                                     roll:Double(face.roll?.doubleValue ?? 0))
        add(detection)
        publish(buffer,pupils:[detection.leftPupil,detection.rightPupil],
                usable:EyePositionEstimator.estimate(from:detection,assumptions:Self.assumptions) != nil)
    }

    /// Hands the frame to the preview, at about ten frames a second: enough to
    /// watch, and one conversion per frame is real work on the capture queue.
    private func publish(_ buffer: CVPixelBuffer, pupils: [CGPoint], usable: Bool) {
        guard let observer = observer() else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now-lastPreview > 0.1 else { return }
        lastPreview = now
        let image = CIImage(cvPixelBuffer:buffer)
        guard let rendered = imageContext.createCGImage(image,from:image.extent) else { return }
        let frame = EyeFrame(image:rendered,pupils:pupils,
                             size:CGSize(width:CVPixelBufferGetWidth(buffer),
                                         height:CVPixelBufferGetHeight(buffer)),
                             usable:usable)
        DispatchQueue.main.async { observer(frame) }
    }
}

extension EyeDetector: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard countSamples() < 40 else { return }
        analyse(buffer)
    }
}
