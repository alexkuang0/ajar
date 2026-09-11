import SwiftUI

struct EffectControls: View {
    @Binding var settings: EffectSettings
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Spatial field").font(.headline)
            Toggle("Metal: show mask",isOn:$settings.debugMask)
            parameter("Maximum blur σ (source px)",value:$settings.maxBlur,range:0...48)
            Toggle("Right → left",isOn:$settings.reversed)
            parameter("Boundary offset",value:$settings.position,range: -0.4...0.4)
            parameter("Curvature",value:$settings.curvature,range: -2...2)
            parameter("Softness",value:$settings.softness,range:0.005...0.3)
            parameter("Perspective",value:$settings.perspective,range:0...0.15)
            parameter("Scale strength",value:$settings.scale,range:0...0.15)
            parameter("Crossfade width",value:$settings.crossfadeWidth,range:0.05...1)
            parameter("Luminance dip",value:$settings.luminance,range:0...0.15)
            parameter("Contrast dip",value:$settings.contrast,range:0...0.15)
            Text("Black = unaffected · white = maximum effect. Blur and tone apply in Metal focus. Perspective and scale also apply in Surfaces.").font(.caption).foregroundStyle(.secondary)
        }
    }
    func parameter(_ name:String,value:Binding<Double>,range:ClosedRange<Double>) -> some View {
        VStack(alignment:.leading,spacing:3) {
            HStack { Text(name); Spacer(); Text(value.wrappedValue,format:.number.precision(.fractionLength(3))).monospacedDigit() }
            Slider(value:value,in:range)
        }
    }
}
