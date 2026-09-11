import Foundation
import QuartzCore

// Display metrics are written/read on the main thread. CPU is process CPU time
// divided by wall time: 100% means one fully occupied core, not all CPU cores.
final class PerformanceMetrics {
    static let shared = PerformanceMetrics()
    private var frames = 0
    private var start = CACurrentMediaTime()
    private var previousCPU = 0.0
    private(set) var fps = 0.0
    private(set) var cpu = 0.0
    private(set) var sampleAgeMs = 0.0
    private(set) var gpuMs = 0.0
    private(set) var motionFrame = MotionFrame()
    // Live overlay: its own draw rate and GPU cost, kept apart from the
    // in-window preview so neither hides the other.
    private(set) var liveFps = 0.0
    private(set) var liveGpuMs = 0.0
    private(set) var liveSkipped = 0
    private var liveFrames = 0
    private var liveSkippedTotal = 0
    func motion(_ frame: MotionFrame) { motionFrame = frame }
    func frame(sampleTimestamp: Double?) {
        frames += 1
        if let sampleTimestamp { sampleAgeMs = (CACurrentMediaTime()-sampleTimestamp)*1000 }
    }
    func gpu(milliseconds: Double) { gpuMs = milliseconds }
    func liveFrame(sampleTimestamp: Double?) {
        liveFrames += 1
        if let sampleTimestamp { sampleAgeMs = (CACurrentMediaTime()-sampleTimestamp)*1000 }
    }
    func live(gpuMilliseconds: Double) { liveGpuMs = gpuMilliseconds }
    func liveSkippedFrame() { liveSkippedTotal += 1 }
    func refresh() {
        let now = CACurrentMediaTime()
        let dt = now-start
        guard dt >= 1 else { return }
        var usage = rusage()
        if getrusage(RUSAGE_SELF,&usage) == 0 {
            let total = Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
            if previousCPU > 0 { cpu = (total-previousCPU)/dt*100 }
            previousCPU = total
        }
        fps = Double(frames)/dt; frames = 0; start = now
        liveFps = Double(liveFrames)/dt; liveFrames = 0
        liveSkipped = liveSkippedTotal; liveSkippedTotal = 0
    }
}
