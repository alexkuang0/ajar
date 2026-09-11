import AppKit
import SwiftUI
import QuartzCore

struct RenderSettings: Equatable {
    var mode = PreviewMode.motion
    var motion = MotionSettings()
    var responseReset = 0
    var effect = EffectSettings()
    var minAngle = 70.0
    var maxAngle = 120.0
}
final class TrackingView: NSView {
    let store: HingeStore
    var settings = RenderSettings()
    private var link: CADisplayLink?
    private var frames = 0
    private var rateStart = CACurrentMediaTime()
    private(set) var fps = 0.0
    init(store: HingeStore) { self.store = store; super.init(frame: .zero); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate(); link = nil
        if window != nil {
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common); self.link = link
        }
    }
    @objc private func tick(_ link: CADisplayLink) { needsDisplay = true }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let now = CACurrentMediaTime()
        frames += 1
        if now - rateStart >= 1 { fps = Double(frames)/(now-rateStart); frames = 0; rateStart = now }
        NSColor(calibratedWhite: 0.065, alpha: 1).setFill(); bounds.fill()
        let state = store.snapshot()
        PerformanceMetrics.shared.frame(sampleTimestamp:state.sample?.timestamp)
        guard let sample = state.sample else { label("Waiting for angle · use Manual if unavailable", x: 28, y: 40); return }
        let p = progress(angle: sample.filteredAngle, minAngle: settings.minAngle, maxAngle: settings.maxAngle)
        label("PHYSICAL SCRUB", x: 28, y: 24)
        label(String(format: "p = %.3f    Draw %.1f FPS    Sample age %.1f ms", p, fps, (now-sample.timestamp)*1000), x: 28, y: 52)
        let width = max(1, bounds.width - 100)
        NSColor.darkGray.setFill(); NSRect(x: 50,y: 134,width: width,height: 2).fill()
        NSColor.cyan.setFill(); NSBezierPath(roundedRect: NSRect(x: 50 + width*p - 14,y: 121,width: 28,height: 28),xRadius: 5,yRadius: 5).fill()
        label(String(format: "%.0f°  /  p = 0", settings.minAngle), x: 35, y: 170)
        label(String(format: "%.0f°  /  p = 1", settings.maxAngle), x: bounds.width-145, y: 170)
        if now - sample.timestamp > 0.25 { label("STALE INPUT — holding last valid angle", x: 28, y: 200, color: .systemRed) }
        if settings.mode == .mask { drawMask(progress:p); return }
        if settings.mode == .surfaces { drawSurfaces(progress:p); return }
        label("RAW / FILTERED  ·  last 4 seconds  ·  cyan / orange", x: 28, y: 226)
        for filtered in [false,true] {
            let path = NSBezierPath(); var first = true
            for s in state.history where now - s.timestamp <= 4 {
                let x = 28 + (1-(now-s.timestamp)/4)*(bounds.width-56)
                let angle = filtered ? s.filteredAngle : s.rawAngle
                let y = 370 - progress(angle: angle,minAngle: settings.minAngle,maxAngle: settings.maxAngle)*100
                if first { path.move(to: NSPoint(x:x,y:y)); first = false } else { path.line(to:NSPoint(x:x,y:y)) }
            }
            (filtered ? NSColor.orange : NSColor.cyan).setStroke(); path.lineWidth = filtered ? 1 : 2; path.stroke()
        }
        if now - sample.timestamp > 0.25 { label("STALE INPUT — holding last valid angle", x: 28, y: 400, color: .systemRed) }
    }
    private func drawMask(progress p: Double) {
        let width = 256, height = 160
        var pixels = [UInt8](repeating:0,count:width*height)
        for y in 0..<height {
            for x in 0..<width {
                pixels[y*width+x] = UInt8((255*effectMask(x:Double(x)/Double(width-1),y:Double(y)/Double(height-1),progress:p,settings:settings.effect)).rounded())
            }
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data:data), let image = CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent), let context = NSGraphicsContext.current?.cgContext else { return }
        label("SPATIAL FIELD  /  BLACK → WHITE",x:28,y:220)
        let rect = NSRect(x:28,y:260,width:bounds.width-56,height:max(120,bounds.height-315))
        context.saveGState(); context.translateBy(x:rect.minX,y:rect.maxY); context.scaleBy(x:1,y: -1)
        context.draw(image,in:CGRect(x:0,y:0,width:rect.width,height:rect.height)); context.restoreGState()
    }
    private func drawSurfaces(progress p: Double) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let state = transition(progress:p,settings:settings.effect)
        let rect = NSRect(x:55,y:260,width:bounds.width-110,height:max(140,bounds.height-325))
        for incoming in [false,true] {
            let opacity = incoming ? state.incomingOpacity : state.outgoingOpacity
            if opacity <= 0 { continue }
            context.saveGState(); context.setAlpha(opacity)
            context.translateBy(x:rect.midX,y:rect.midY)
            let scale = incoming ? state.incomingScale : state.outgoingScale
            let tilt = incoming ? state.incomingTilt : state.outgoingTilt
            context.concatenate(CGAffineTransform(a:scale,b:tilt,c:0,d:scale,tx:incoming ? state.incomingTranslation : state.outgoingTranslation,ty:0))
            let card = NSRect(x: -rect.width/2,y: -rect.height/2,width:rect.width,height:rect.height)
            (incoming ? NSColor(calibratedRed:0.38,green:0.19,blue:0.10,alpha:1) : NSColor(calibratedRed:0.06,green:0.23,blue:0.34,alpha:1)).setFill()
            NSBezierPath(roundedRect:card,xRadius:18,yRadius:18).fill()
            label(incoming ? "SURFACE B  /  AMBER" : "SURFACE A  /  OCEAN",x:card.minX+24,y:card.minY+28,color:.white)
            label(incoming ? "Ideas in warm light" : "A quiet place to focus",x:card.minX+24,y:card.minY+68,color:.white)
            for index in 0..<4 {
                NSColor.white.withAlphaComponent(0.12+Double(index)*0.05).setFill()
                NSBezierPath(roundedRect:NSRect(x:card.minX+24,y:card.minY+110+Double(index)*38,width:card.width-48-Double(index%2)*65,height:22),xRadius:5,yRadius:5).fill()
            }
            context.restoreGState()
        }
        label("TWO SURFACES / PURE PROGRESS · affine depth study",x:28,y:220)
    }
    func label(_ text: String, x: Double, y: Double, color: NSColor = .lightGray) {
        (text as NSString).draw(at: NSPoint(x:x,y:y), withAttributes: [.font:NSFont.monospacedSystemFont(ofSize:12,weight:.medium),.foregroundColor:color])
    }
}
struct TransitionView: NSViewRepresentable {
    let store: HingeStore
    let settings: RenderSettings
    func makeNSView(context: Context) -> TrackingView { TrackingView(store:store) }
    func updateNSView(_ view: TrackingView, context: Context) { view.settings = settings }
}
