import Foundation
import QuartzCore

struct HingeSnapshot {
    var sample: HingeSample?
    var history: [HingeSample] = []
    var status = "Starting sensor…"
    var readHz = 0.0
    var changeHz = 0.0
    var readMilliseconds = 0.0
    var observedMin = Double.infinity
    var observedMax = -Double.infinity
    var failures = 0
    var logStatus = "Logging off"
}

final class HingeStore {
    private let queue = DispatchQueue(label: "hinge.acquisition", qos: .userInteractive)
    private let lock = NSLock()
    private var state = HingeSnapshot()
    private var source: HingeAngleSource = PhysicalHingeSource()
    private var filter = HingeFilter()
    private var tau = 0.0
    private var timer: DispatchSourceTimer?
    private var reads = 0, changes = 0
    private var rateStart = CACurrentMediaTime()
    private var lastRaw: Double?
    private var log: FileHandle?
    private var loggedRows = 0

    func snapshot() -> HingeSnapshot { lock.lock(); defer { lock.unlock() }; return state }
    private func mutate(_ body: (inout HingeSnapshot) -> Void) { lock.lock(); defer { lock.unlock() }; body(&state) }
    func start() { usePhysical(true) }
    /// Which source is selected, for a panel that has to show the same thing.
    func isManualInput() -> Bool { queue.sync { source is ManualHingeSource } }
    func usePhysical(_ physical: Bool) {
        queue.async {
            self.timer?.cancel(); self.timer = nil
            self.source.stop()
            self.source = physical ? PhysicalHingeSource() : ManualHingeSource()
            self.filter.reset(); self.lastRaw = nil
            self.reads = 0; self.changes = 0; self.rateStart = CACurrentMediaTime()
            self.mutate { $0 = HingeSnapshot(); $0.logStatus = self.log == nil ? "Logging off" : "Recording CSV" }
            do {
                try self.source.start()
                self.mutate { $0.status = self.source.name }
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .microseconds(300))
                timer.setEventHandler { [weak self] in self?.poll() }
                self.timer = timer; timer.resume()
            } catch { self.source.stop(); self.mutate { $0.status = error.localizedDescription } }
        }
    }
    func setManual(_ angle: Double) { queue.async { (self.source as? ManualHingeSource)?.angle = angle } }
    func setFilter(_ milliseconds: Double) { queue.async { self.tau = milliseconds / 1000; self.filter.reset() } }
    func setLogging(_ url: URL?) {
        queue.async {
            try? self.log?.close(); self.log = nil; self.loggedRows = 0
            guard let url else { self.mutate { $0.logStatus = "Logging off" }; return }
            do {
                try Data("uptime_s,raw_deg,filtered_deg,velocity_deg_s,read_ms\n".utf8).write(to: url)
                self.log = try FileHandle(forWritingTo: url); try self.log?.seekToEnd()
                self.mutate { $0.logStatus = "CSV: \(url.lastPathComponent)" }
            } catch { self.mutate { $0.logStatus = error.localizedDescription } }
        }
    }
    private func poll() {
        let before = CACurrentMediaTime()
        do {
            let raw = try source.read()
            let now = CACurrentMediaTime()
            let sample = filter.update(raw: raw, timestamp: now, timeConstant: tau)
            reads += 1
            if let lastRaw, lastRaw != raw { changes += 1 }
            lastRaw = raw
            mutate {
                $0.sample = sample; $0.status = source.name
                $0.history.append(sample)
                if $0.history.count > 500 { $0.history.removeFirst($0.history.count - 500) }
                $0.observedMin = min($0.observedMin, raw); $0.observedMax = max($0.observedMax, raw)
                $0.readMilliseconds = (now - before) * 1000
            }
            if let log {
                do {
                    try log.write(contentsOf: Data("\(now),\(raw),\(sample.filteredAngle),\(sample.angularVelocity),\((now-before)*1000)\n".utf8))
                    loggedRows += 1
                    if loggedRows >= 75000 { try log.close(); self.log = nil; mutate { $0.logStatus = "CSV complete (75,000 sample limit)" } }
                } catch { try? log.close(); self.log = nil; mutate { $0.logStatus = "CSV error: \(error.localizedDescription)" } }
            }
        } catch { mutate { $0.failures += 1; $0.status = error.localizedDescription } }
        let elapsed = CACurrentMediaTime() - rateStart
        if elapsed >= 1 {
            mutate { $0.readHz = Double(reads) / elapsed; $0.changeHz = Double(changes) / elapsed }
            reads = 0; changes = 0; rateStart = CACurrentMediaTime()
        }
    }
    func stop() {
        queue.sync { timer?.cancel(); timer = nil; source.stop(); try? log?.close(); log = nil }
    }
}
