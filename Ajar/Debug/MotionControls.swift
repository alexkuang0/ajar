import SwiftUI

struct MotionControls: View {
    @Binding var settings: MotionSettings
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Rig").font(.headline)
            parameter("Ignore wobble below (°)",value:$settings.wobbleDeadband,range:0...3)
            parameter("Movement window (s)",value:$settings.motionWindow,range:0.1...1.5)
            Text("Motion response").font(.headline)
            parameter("Frame smoothing (ms)",value:$settings.smoothingMs,range:15...150)
            parameter("Catch-up time (s)",value:$settings.settleSeconds,range:0.5...4)
            parameter("Frosting over (°)",value:$settings.blurSpan,range:5...90)
            parameter("Maximum blur σ (px)",value:$settings.maxBlur,range:0...48)
            Picker("Depth field",selection:$settings.field) {
                ForEach(MotionField.allCases,id:\.self) { Text($0.rawValue).tag($0) }
            }
            Toggle("Invert depth (hinge ↔ free edge)",isOn:$settings.reversed)
            Toggle("Show blur-strength field",isOn:$settings.debugMask)
            Toggle("Reverse rotation (co-rotate with lid)",isOn:$settings.reverseRotation)
            if settings.field == .hinge {
                parameter("Softness",value:$settings.softness,range:0.15...0.8)
                parameter("Curvature",value:$settings.curvature,range: -0.4...0.4)
            }
            parameter("Still before catch-up (s)",value:$settings.stillDelay,range:0...1)
            Text("Live overlay").font(.headline)
            parameter("Overlay fade in (mask)",value:$settings.overlayFadeStart,range:0...0.2)
            parameter("Overlay fully opaque (mask)",value:$settings.overlayFadeEnd,range:0.01...0.4)
            Text("On the built-in display the effect is drawn over the real screen, and these two values decide where it stops being see-through. Below the first value the overlay is transparent, so the untouched screen shows; above the second it is opaque. Keep the band narrow: a wide one leaves the original, unmoved screen showing through the lower half of the picture, which reads as a rendering bug rather than as depth. At rest the mask is zero everywhere, so the overlay is invisible whatever these are set to.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Travel accumulates the effect: blur and tilt grow with how far the lid has moved from the last settled angle, up to the delta above. At rest the picture fills the screen; tilting it away swings the free edge down and slides the black padding in from above, left and right. The padding is part of the blurred image, so the border softens rather than cutting. The further from the hinge, the heavier the blur.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func parameter(_ name: String,value:Binding<Double>,range:ClosedRange<Double>) -> some View {
        VStack(alignment:.leading,spacing:3) {
            HStack { Text(name); Spacer(); Text(value.wrappedValue,format:.number.precision(.fractionLength(2))).monospacedDigit() }
            Slider(value:value,in:range)
        }
    }
}
