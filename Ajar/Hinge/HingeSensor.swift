import Foundation
import IOKit.hid

// Acquisition runs only on the store's serial queue; it never touches the UI.
protocol HingeAngleSource: AnyObject {
    var name: String { get }
    func start() throws
    func read() throws -> Double
    func stop()
}
struct SensorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
final class ManualHingeSource: HingeAngleSource {
    let name = "Manual slider"
    var angle = 100.0
    func start() throws {}
    func read() throws -> Double { angle }
    func stop() {}
}
final class PhysicalHingeSource: HingeAngleSource {
    private(set) var name = "Apple SPU · 05ac:8104"
    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    /// Tried in the order `HingeCapability.sensorMatches` lists them, so a Mac
    /// that answers on the standard Sensor page and one that only exposes the
    /// product under a vendor-specific page both work.
    func start() throws {
        stop()
        var lastError = "no lid angle device (0x5ac:0x8104) on this Mac"
        for match in HingeCapability.sensorMatches {
            let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
            IOHIDManagerSetDeviceMatching(manager, match.dictionary as CFDictionary)
            let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                lastError = "HID open failed (\(result)). Launch outside the sandbox; no sudo is needed."
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                continue
            }
            let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
            guard let device = devices.first else {
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                continue
            }
            let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard opened == kIOReturnSuccess else {
                lastError = "device open failed (\(opened))"
                IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
                continue
            }
            self.manager = manager
            self.device = device
            name = "Apple SPU · 05ac:8104 · \(match.label)"
            return
        }
        throw SensorError(message:"\(lastError). Run Scripts/diagnose.sh to scan for it, or use Manual input.")
    }
    func read() throws -> Double {
        guard let device else { throw SensorError(message: "Sensor disconnected") }
        var bytes = [UInt8](repeating: 0, count: 8)
        var length = bytes.count
        // Inspected in samhenrigold/LidAngleSensor: feature report 1,
        // little-endian UInt16 degrees at bytes 1...2. Not a fractional value.
        let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &length)
        guard result == 0, length >= 3, bytes[0] == 1 else { throw SensorError(message: "Report read failed (\(result), \(length) bytes)") }
        let angle = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
        guard angle <= 180 else { throw SensorError(message: "Unexpected angle report: \(angle)") }
        return angle
    }
    func stop() {
        if let device { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let manager { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        device = nil; manager = nil
    }
    deinit { stop() }
}
