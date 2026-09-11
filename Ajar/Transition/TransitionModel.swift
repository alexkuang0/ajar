import Foundation

enum PreviewMode: String, CaseIterable { case motion = "Motion / settle", tracking = "Tracking", surfaces = "Surfaces", mask = "Spatial mask", metal = "Angle scrub (old)" }
struct EffectSettings: Equatable {
    var maxBlur = 32.0
    var debugMask = false
    var luminance = 0.035
    var contrast = 0.05
    var position = 0.0
    var reversed = false
    var curvature = 0.8
    var softness = 0.08
    var perspective = 0.04
    var scale = 0.06
    var crossfadeWidth = 0.3
}
struct SurfaceState: Equatable {
    let outgoingOpacity: Double
    let incomingOpacity: Double
    let outgoingScale: Double
    let incomingScale: Double
    let outgoingTranslation: Double
    let incomingTranslation: Double
    let outgoingTilt: Double
    let incomingTilt: Double
}
func smoothstep(_ lower: Double, _ upper: Double, _ value: Double) -> Double {
    let t = min(1,max(0,(value-lower)/max(0.000001,upper-lower)))
    return t*t*(3-2*t)
}
func transition(progress p: Double, settings: EffectSettings) -> SurfaceState {
    let p = min(1,max(0,p))
    let mix = smoothstep(0.5-settings.crossfadeWidth/2,0.5+settings.crossfadeWidth/2,p)
    return SurfaceState(outgoingOpacity:1-mix,incomingOpacity:mix,
                        outgoingScale:1-settings.scale*p,incomingScale:1+settings.scale*(1-p),
                        outgoingTranslation: -24*p,incomingTranslation:24*(1-p),
                        outgoingTilt:settings.perspective*p,incomingTilt: -settings.perspective*(1-p))
}
func boundary(y: Double, progress p: Double, settings: EffectSettings) -> Double {
    // Dynamic margin preserves completely black/white endpoints across all controls.
    let margin = 0.02 + abs(settings.curvature)*0.25 + settings.softness + abs(settings.position)
    return -margin + (1+2*margin)*p + settings.position + settings.curvature*pow(y-0.5,2)
}
func effectMask(x: Double, y: Double, progress p: Double, settings: EffectSettings) -> Double {
    let x = settings.reversed ? 1-x : x
    let d = x - boundary(y:y,progress:p,settings:settings)
    // Affected side trails the moving boundary: p=0 black, p=1 white.
    return 1-smoothstep(-settings.softness,settings.softness,d)
}
