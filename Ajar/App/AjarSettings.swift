import Foundation
import SwiftUI

/// The settings a normal user is expected to have an opinion about, persisted
/// between launches.
///
/// The debug window keeps its own copy of everything for experiments; these are
/// the ones that decide how the effect behaves for someone who just installed
/// the app, and they are what the overlay renders with when no debug window is
/// open.
final class AjarSettings: ObservableObject {
    static let shared = AjarSettings()

    @Published var eyeDistance: Double { didSet { write(eyeDistance,key:"eyeDistance") } }
    @Published var eyeHeight: Double { didSet { write(eyeHeight,key:"eyeHeight") } }
    @Published var blurSpan: Double { didSet { write(blurSpan,key:"blurSpan") } }
    @Published var maxBlur: Double { didSet { write(maxBlur,key:"maxBlur") } }
    /// Whether the effect should be on. Off until the walkthrough is finished,
    /// on afterwards by default, and whatever the user last chose from then on —
    /// the menu bar toggle writes it back, so turning the effect off sticks.
    @Published var effectEnabled: Bool { didSet { defaults.set(effectEnabled,forKey:"effectEnabled") } }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fallback = MotionSettings()
        eyeDistance = defaults.object(forKey:"eyeDistance") as? Double ?? fallback.eyeDistance
        eyeHeight = defaults.object(forKey:"eyeHeight") as? Double ?? fallback.eyeHeight
        blurSpan = defaults.object(forKey:"blurSpan") as? Double ?? fallback.blurSpan
        maxBlur = defaults.object(forKey:"maxBlur") as? Double ?? fallback.maxBlur
        effectEnabled = defaults.bool(forKey:"effectEnabled")
    }

    /// The motion settings the overlay should render with.
    var motion: MotionSettings {
        var settings = MotionSettings()
        settings.eyeDistance = eyeDistance
        settings.eyeHeight = eyeHeight
        settings.blurSpan = blurSpan
        settings.maxBlur = maxBlur
        return settings
    }

    /// The same, wrapped as the render settings the overlay consumes.
    var renderSettings: RenderSettings {
        var render = RenderSettings()
        render.motion = motion
        return render
    }

    /// Applies these to a debug-window copy, keeping the fields the debug window
    /// owns (the rig, the field shape, the overlay fade) exactly as they are.
    func apply(to settings: inout RenderSettings) {
        settings.motion.eyeDistance = eyeDistance
        settings.motion.eyeHeight = eyeHeight
        settings.motion.blurSpan = blurSpan
        settings.motion.maxBlur = maxBlur
    }

    func reset() {
        let fallback = MotionSettings()
        eyeDistance = fallback.eyeDistance
        eyeHeight = fallback.eyeHeight
        blurSpan = fallback.blurSpan
        maxBlur = fallback.maxBlur
    }

    private func write(_ value: Double, key: String) { defaults.set(value,forKey:key) }
}

extension Notification.Name {
    /// Posted when the settings window changes a value the debug window also
    /// holds, so the two stop overwriting each other.
    static let adoptUserSettings = Notification.Name("dev.kuang.ajar.adoptUserSettings")
}
