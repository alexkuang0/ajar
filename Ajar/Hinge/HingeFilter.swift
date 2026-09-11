import Foundation

struct HingeSample {
    let timestamp: TimeInterval // Monotonic system uptime, seconds.
    let rawAngle: Double
    let filteredAngle: Double
    let angularVelocity: Double
}

struct HingeFilter {
    private var previous: HingeSample?
    mutating func reset() { previous = nil }
    mutating func update(raw: Double, timestamp: Double, timeConstant: Double) -> HingeSample {
        let dt = previous.map { timestamp - $0.timestamp } ?? 0
        let valid = dt > 0 && dt < 0.5
        let alpha = timeConstant <= 0 || !valid ? 1 : 1 - exp(-dt / timeConstant)
        let filtered = (previous?.filteredAngle ?? raw) + alpha * (raw - (previous?.filteredAngle ?? raw))
        let velocity = valid ? (filtered - previous!.filteredAngle) / dt : 0
        let sample = HingeSample(timestamp: timestamp, rawAngle: raw, filteredAngle: filtered, angularVelocity: velocity)
        previous = sample
        return sample
    }
}

func progress(angle: Double, minAngle: Double, maxAngle: Double) -> Double {
    guard angle.isFinite, minAngle.isFinite, maxAngle.isFinite, maxAngle > minAngle else { return 0 }
    return min(1, max(0, (angle - minAngle) / (maxAngle - minAngle)))
}
