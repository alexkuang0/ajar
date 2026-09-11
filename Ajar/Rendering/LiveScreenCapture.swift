import AppKit
import CoreMedia
import CoreVideo
import ScreenCaptureKit

/// Frames from the laptop's own panel, via ScreenCaptureKit.
///
/// The capture side only publishes the newest pixel buffer; drawing pulls it at
/// the display cadence. A draw that blocks or skips therefore never applies back
/// pressure to the capture queue, and the newest frame is always the one drawn.
/// Our own windows are excluded from the stream so the overlay cannot capture
/// itself.
final class LiveScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    enum State: Equatable {
        case idle
        case noPermission
        case starting
        case running(width: Int, height: Int)
        case failed(String)

        var text: String {
            switch self {
            case .idle: return "Capture off"
            case .noPermission: return "Screen Recording permission needed"
            case .starting: return "Starting capture…"
            case .running(let width, let height): return "Capturing built-in display at \(width)×\(height)"
            case .failed(let message): return "Capture failed: \(message)"
            }
        }
        var isRunning: Bool { if case .running = self { return true }; return false }
    }

    private(set) var state = State.idle
    /// Called on the main queue whenever the state changes.
    var onState: ((State) -> Void)?

    private let queue = DispatchQueue(label: "hinge.capture", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var display: SCDisplay?
    private var watchedWindow: CGWindowID = 0
    private var excludedWindows: Set<CGWindowID> = []
    private var latest: CVPixelBuffer?
    private var latestTime = 0.0
    private var frames = 0
    private var rateStart = CACurrentMediaTime()
    private var rate = 0.0
    /// Bumped by every start/stop so a slow async start cannot outlive a stop.
    private var generation = 0 // guarded by `lock`
    /// True once the running stream's filter excludes the overlay window.
    ///
    /// The window server does not publish a window to ScreenCaptureKit until
    /// roughly half a second after it is ordered front, so the first filter this
    /// process can build is empty. Drawing before the filter catches up would
    /// capture the overlay into itself and compound the transform every frame —
    /// which looks exactly like a runaway zoom — so the renderer refuses to draw
    /// until this is true.
    private var excludingOwnWindows = false // guarded by `lock`

    /// Whether the running stream's filter excludes the overlay window.
    var isExcludingOwnWindows: Bool { lock.lock(); defer { lock.unlock() }; return excludingOwnWindows }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }
    static func openPermissionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Successful frames per second, averaged over the last second.
    var framesPerSecond: Double { lock.lock(); defer { lock.unlock() }; return rate }
    var deliveredFrames: Int { lock.lock(); defer { lock.unlock() }; return frames }

    /// The newest frame and its CPU arrival time, or nil if nothing has arrived.
    func takeLatest() -> (buffer: CVPixelBuffer, time: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let latest else { return nil }
        return (latest, latestTime)
    }

    func start(displayID: CGDirectDisplayID, overlayWindow: CGWindowID) {
        guard stream == nil else { return }
        guard Self.hasPermission else { publish(.noPermission); return }
        lock.lock()
        watchedWindow = overlayWindow
        excludingOwnWindows = false
        excludedWindows = []
        lock.unlock()
        let token = bumpGeneration()
        publish(.starting)
        Task { await startStream(displayID: displayID, token: token) }
    }

    func stop() {
        _ = bumpGeneration()
        let stream = self.stream
        self.stream = nil
        lock.lock()
        latest = nil; rate = 0; frames = 0
        excludingOwnWindows = false; excludedWindows = []; display = nil
        lock.unlock()
        publish(.idle)
        guard let stream else { return }
        Task { try? await stream.stopCapture() }
    }

    private func bumpGeneration() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        return generation
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation
    }

    private func startStream(displayID: CGDirectDisplayID, token: Int) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard isCurrent(token) else { return }
            guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first(where: { CGDisplayIsBuiltin($0.displayID) != 0 }) else {
                publish(.failed("No display to capture")); return
            }
            // Exclude every window this process owns (the control panel and the
            // overlay itself) so the stream never feeds back into the overlay.
            let ownPID = getpid()
            let excluded = content.windows.filter { $0.owningApplication?.processID == ownPID }
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.captureResolution = .best
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            configuration.queueDepth = 6
            configuration.showsCursor = false
            configuration.scalesToFit = false
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: excluded),
                                  configuration: configuration, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await stream.startCapture()
            guard isCurrent(token), self.stream == nil else { try? await stream.stopCapture(); return }
            self.stream = stream
            self.display = display
            await applyExclusion(stream: stream, display: display, token: token)
            publish(.running(width: display.width, height: display.height))
            await keepExclusionCurrent(stream:stream, display:display, token:token)
        } catch {
            guard isCurrent(token) else { return }
            if !Self.hasPermission { publish(.noPermission) } else { publish(.failed(error.localizedDescription)) }
        }
    }

    private func publish(_ value: State) {
        guard value != state else { return }
        state = value
        DispatchQueue.main.async { self.onState?(value) }
    }

    /// Rebuilds the stream's filter with every window this process owns.
    ///
    /// This has to run *after* `startCapture`, and repeatedly: the window server
    /// does not publish a new window to ScreenCaptureKit until about half a
    /// second after it is ordered front, so the first filter this process can
    /// build is empty. Until the overlay is in it, `isExcludingOwnWindows` stays
    /// false and the renderer keeps its window empty.
    @discardableResult
    private func applyExclusion(stream: SCStream, display: SCDisplay, token: Int) async -> Bool {
        guard isCurrent(token) else { return false }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return false }
        guard isCurrent(token) else { return false }
        let ownPID = getpid()
        let own = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let identifiers = Set(own.map(\.windowID))
        let decision = filterDecision(for:identifiers)
        if decision.changed && !own.isEmpty {
            do { try await stream.updateContentFilter(SCContentFilter(display:display,excludingWindows:own)) }
            catch {
                NSLog("Ajar capture: could not update the content filter: %@", error.localizedDescription)
                return false
            }
            recordAppliedFilter(identifiers)
        }
        return publishExclusion(decision.covered, known: identifiers.count, watched: decision.watched)
    }

    private struct FilterDecision { let changed: Bool; let covered: Bool; let watched: CGWindowID }

    private func filterDecision(for identifiers: Set<CGWindowID>) -> FilterDecision {
        lock.lock(); defer { lock.unlock() }
        let watched = watchedWindow
        return FilterDecision(changed: identifiers != excludedWindows,
                              covered: identifiers.contains(watched) || excludedWindows.contains(watched),
                              watched: watched)
    }

    private func recordAppliedFilter(_ identifiers: Set<CGWindowID>) {
        lock.lock(); defer { lock.unlock() }
        excludedWindows = identifiers
    }

    private func publishExclusion(_ covered: Bool, known: Int, watched: CGWindowID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if excludingOwnWindows != covered {
            excludingOwnWindows = covered
            NSLog("Ajar capture: overlay window %u %@ the exclusion list (%d own window(s) known)",
                  watched, covered ? "is in" : "is NOT in", known)
        }
        return covered
    }

    /// Keeps the exclusion list in step while the overlay is open: a window of
    /// ours that appears later (the control panel, for instance) would otherwise
    /// be captured into the picture.
    private func keepExclusionCurrent(stream: SCStream, display: SCDisplay, token: Int) async {
        var delay = 0.2
        while isCurrent(token), self.stream === stream {
            try? await Task.sleep(nanoseconds: UInt64(delay*1_000_000_000))
            guard isCurrent(token), self.stream === stream else { return }
            await applyExclusion(stream:stream,display:display,token:token)
            delay = min(3.0, delay*2) // 0.2 s, 0.4 s, 0.8 s, then every 3 s
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = buffer
        latestTime = CACurrentMediaTime()
        frames += 1
        let elapsed = latestTime - rateStart
        if elapsed >= 1 {
            rate = Double(frames) / elapsed
            frames = 0
            rateStart = latestTime
        }
        lock.unlock()
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        if !Self.hasPermission { publish(.noPermission) } else { publish(.failed(error.localizedDescription)) }
    }
}
