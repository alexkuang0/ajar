import Foundation
import CoreGraphics
import IOKit.hid

/// Whether this Mac has a hinge angle sensor, and whether it can be read.
///
/// Two independent answers are needed. The model tells you what Apple shipped,
/// and the runtime probe tells you what this particular machine will actually
/// hand over — a model on the list can still fail to open, and an unlisted one
/// can still work. Onboarding shows both; nothing is gated on the model alone.
///
/// The model lists mirror the community-maintained ones in
/// samhenrigold/LidAngleSensor (HardwareCompat.swift), which is also where the
/// report format came from. Apple does not publish either.
enum HingeCapability {
    enum Support: Equatable {
        case supported(String)
        case unknown(String)
        case unsupported(String)
    }
    enum Probe: Equatable {
        case readable(angle: Double, usage: String)
        case unreadable(String)
        case missing

        var isReadable: Bool { if case .readable = self { return true }; return false }
    }

    /// `sysctl hw.model`, e.g. `MacBookPro18,3`.
    static var modelIdentifier: String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func support(for identifier: String = modelIdentifier) -> Support {
        if let name = supportedModels[identifier] { return .supported(name) }
        if let reason = unsupportedReason(for: identifier) { return .unsupported(reason) }
        return .unknown(identifier)
    }

    /// Model identifier and marketing name when known, e.g. "MacBookPro18,3".
    static var modelDescription: String {
        switch support() {
        case .supported(let name): return "\(name) (\(modelIdentifier))"
        case .unknown(let id): return "Unrecognised Mac (\(id))"
        case .unsupported(let reason): return "\(modelIdentifier) — \(reason)"
        }
    }

    /// One line for the onboarding screen.
    static var summary: String {
        switch (support(), probe()) {
        case (.unsupported(let reason), _):
            return "\(modelIdentifier). \(reason)"
        case (_, .readable(let angle, let usage)):
            return "\(modelDescription) — sensor readable on \(usage), currently \(String(format:"%.0f°",angle))."
        case (_, .unreadable(let message)):
            return "\(modelDescription) — the sensor is present but would not open: \(message)"
        case (_, .missing):
            return "\(modelDescription) — no lid angle sensor found on this Mac."
        }
    }

    /// Opens the sensor, reads one report, closes it again. Safe to call while
    /// the store is polling: it uses its own manager and device handle.
    static func probe() -> Probe {
        for match in sensorMatches {
            guard let device = firstDevice(matching: match.dictionary) else { continue }
            let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard opened == kIOReturnSuccess else {
                return .unreadable("device open failed (\(opened))")
            }
            defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
            var bytes = [UInt8](repeating: 0, count: 8)
            var length = bytes.count
            let result = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 1, &bytes, &length)
            guard result == kIOReturnSuccess, length >= 3, bytes[0] == 1 else {
                return .unreadable("feature report 1 unavailable (\(result), \(length) bytes)")
            }
            let angle = Double(UInt16(bytes[1]) | UInt16(bytes[2]) << 8)
            guard angle <= 180 else { return .unreadable("unexpected angle value \(angle)") }
            return .readable(angle:angle,usage:match.label)
        }
        return .missing
    }

    /// Ask the system to show the Screen Recording prompt without changing state.
    static var hasScreenCapturePermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the system prompt (once per app) — the grant itself happens in
    /// System Settings, and only applies to a freshly launched process.
    static func requestScreenCapturePermission() { _ = CGRequestScreenCaptureAccess() }

    static func openScreenCaptureSettings() { LiveScreenCapture.openPermissionSettings() }

    struct SensorMatch {
        let label: String
        let dictionary: [String: Any]
    }

    /// Tried in order. The first is the standard Sensor page (0x20) orientation
    /// usage (0x8A) that every Mac with the sensor has answered on so far; the
    /// second finds the same product under a vendor-specific usage page, which
    /// means the hardware is there but the angle may not be readable.
    static let sensorMatches: [SensorMatch] = [
        SensorMatch(label:"Sensor page 0x20 / orientation 0x8A",
                    dictionary:["VendorID": 0x5ac, "ProductID": 0x8104, "PrimaryUsagePage": 32, "PrimaryUsage": 138]),
        SensorMatch(label:"vendor-specific page",
                    dictionary:["VendorID": 0x5ac, "ProductID": 0x8104]),
    ]

    private static func firstDevice(matching dictionary: [String: Any]) -> IOHIDDevice? {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        IOHIDManagerSetDeviceMatching(manager, dictionary as CFDictionary)
        let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []
        return devices.first
    }

    // MARK: Model lists

    private static let supportedModels: [String: String] = [
        // MacBook Pro 16-inch, 2019 — the only Intel MacBook with the sensor.
        "MacBookPro16,1": "MacBook Pro (16-inch, 2019)",
        "MacBookPro16,4": "MacBook Pro (16-inch, 2019)",
        // MacBook Pro 14/16-inch, 2021 (M1 Pro/Max).
        "MacBookPro18,1": "MacBook Pro (16-inch, 2021)",
        "MacBookPro18,2": "MacBook Pro (16-inch, 2021)",
        "MacBookPro18,3": "MacBook Pro (14-inch, 2021)",
        "MacBookPro18,4": "MacBook Pro (14-inch, 2021)",
        // MacBook Pro 14/16-inch, 2023 (M2 Pro/Max).
        "Mac14,5": "MacBook Pro (14-inch, 2023)",
        "Mac14,6": "MacBook Pro (16-inch, 2023)",
        "Mac14,9": "MacBook Pro (14-inch, 2023)",
        "Mac14,10": "MacBook Pro (16-inch, 2023)",
        // MacBook Pro 14/16-inch, Nov 2023 (M3).
        "Mac15,3": "MacBook Pro (14-inch, M3, 2023)",
        "Mac15,6": "MacBook Pro (14-inch, M3 Pro, 2023)",
        "Mac15,7": "MacBook Pro (16-inch, M3 Pro, 2023)",
        "Mac15,8": "MacBook Pro (14-inch, M3 Max, 2023)",
        "Mac15,9": "MacBook Pro (16-inch, M3 Max, 2023)",
        "Mac15,11": "MacBook Pro (16-inch, M3 Max, 2023)",
        // MacBook Pro 14/16-inch, 2024 (M4).
        "Mac16,1": "MacBook Pro (14-inch, M4, 2024)",
        "Mac16,5": "MacBook Pro (16-inch, M4 Pro, 2024)",
        "Mac16,6": "MacBook Pro (14-inch, M4 Pro, 2024)",
        "Mac16,7": "MacBook Pro (16-inch, M4 Max, 2024)",
        "Mac16,8": "MacBook Pro (14-inch, M4 Max, 2024)",
        "Mac16,9": "MacBook Pro (16-inch, M4 Max, 2024)",
        "Mac16,10": "MacBook Pro (16-inch, M4 Max, 2024)",
        // MacBook Air M2 and later.
        "Mac14,2": "MacBook Air (M2, 2022)",
        "Mac14,15": "MacBook Air (15-inch, M2, 2023)",
        "Mac16,12": "MacBook Air (13-inch, M4, 2025)",
        "Mac16,13": "MacBook Air (15-inch, M4, 2025)",
    ]

    private static func unsupportedReason(for identifier: String) -> String? {
        if ["Macmini","MacPro","iMac"].contains(where: { identifier.hasPrefix($0) }) {
            return "Desktop Macs have no lid, so no lid angle sensor."
        }
        if ["Mac13,1","Mac13,2","Mac14,13","Mac14,14","Mac16,2","Mac16,3","Mac16,4","Mac16,11"].contains(identifier) {
            return "This desktop Mac has no lid angle sensor."
        }
        if ["MacBookPro17,1","Mac14,7","MacBookPro15,2","MacBookPro15,4","MacBookPro16,2","MacBookPro16,3"].contains(identifier) {
            return "The 13-inch MacBook Pro never had a lid angle sensor."
        }
        if ["MacBookPro15,1","MacBookPro15,3"].contains(identifier) || ["MacBookPro14,","MacBookPro13,","MacBookPro12,","MacBookPro11,","MacBookPro10,"].contains(where: { identifier.hasPrefix($0) }) {
            return "This MacBook Pro predates the lid angle sensor, which arrived with the 16-inch 2019 model."
        }
        if identifier.hasPrefix("MacBookAir") {
            return "MacBook Air gained the lid angle sensor with the M2 (2022)."
        }
        if identifier.hasPrefix("MacBook") && !identifier.hasPrefix("MacBookPro") && !identifier.hasPrefix("MacBookAir") {
            return "The 12-inch MacBook has no lid angle sensor."
        }
        return nil
    }
}
