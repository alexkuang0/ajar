import AppKit
import SwiftUI

/// Side view of the laptop with the viewer as a draggable dot.
///
/// Written as an AppKit view rather than a SwiftUI `Canvas` with a drag gesture,
/// because a gesture inside a `ScrollView` competes with the scroll view's own
/// pan and loses: the drag reported its position only when the button came up,
/// so the dot jumped instead of following. A view that handles `mouseDragged`
/// itself has no such competition, and it redraws on every event.
final class CameraRigView: NSView {
    /// The viewer's position in the room: metres of screen height in front of the
    /// hinge, and above the hinge plane.
    var eyeDistance: Double = 2.4 { didSet { needsDisplay = true } }
    var eyeHeight: Double = 2.2 { didSet { needsDisplay = true } }
    /// The real lid angle, so the rig is drawn in the pose the laptop is in.
    var lidAngle: Double = 110 { didSet { needsDisplay = true } }
    /// Called continuously while dragging, in room coordinates.
    var onMove: ((Double, Double) -> Void)?

    private let margin: CGFloat = 26
    private let reach: Double = 4.0
    private let height: Double = 3.4

    override var isFlipped: Bool { false }   // y up, so room coordinates map straight over
    override var acceptsFirstResponder: Bool { true }
    /// A real height, so SwiftUI hands this view a size instead of the nothing a
    /// representable gets inside a `ScrollView` — measured at 0 points, which
    /// collapsed the picture to a speck.
    override var intrinsicContentSize: NSSize { NSSize(width:NSView.noIntrinsicMetric,height:340) }

    // MARK: geometry

    /// Everything the room draws, including the space the screen leans back
    /// through, which is what the scale has to fit rather than the grid alone.
    private var span: Double { leanRoom + reach }
    private var scale: Double {
        let fit = min(Double(bounds.width-margin*2)/span, Double(bounds.height-margin*2)/height)
        return max(fit,8)   // a zero-size bounds must not invert the drawing
    }
    /// Centred in whatever room it is given, with the hinge `leanRoom` in from
    /// the left edge. Drag and draw both read this, so they cannot disagree.
    private var origin: CGPoint {
        let slackX = max(0,Double(bounds.width-margin*2)-span*scale)
        let slackY = max(0,Double(bounds.height-margin*2)-height*scale)
        return CGPoint(x:margin+CGFloat(leanRoom*scale+slackX/2),y:margin+CGFloat(slackY/2))
    }
    /// Room on the left for the screen, which leans away past vertical.
    private var leanRoom: Double { 1.0 }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x:origin.x+CGFloat(x*scale),y:origin.y+CGFloat(y*scale))
    }

    /// The panel's own axes at this lid angle: `up` along the screen from the
    /// hinge, `out` along its normal towards the viewer.
    private var axes: (up: (x: Double, y: Double), out: (x: Double, y: Double)) {
        CameraRig.axes(lidAngle:lidAngle)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect:bounds,xRadius:10,yRadius:10).fill()

        drawGrid()

        let pivot = point(0,0)
        let axes = self.axes
        let base = NSBezierPath()
        base.move(to:pivot)
        base.line(to:point(1.05,0))
        base.lineWidth = 6
        base.lineCapStyle = .round
        NSColor.secondaryLabelColor.setStroke()
        base.stroke()

        let panel = NSBezierPath()
        panel.move(to:pivot)
        panel.line(to:point(axes.up.x,axes.up.y))
        panel.lineWidth = 5
        panel.lineCapStyle = .round
        NSColor.labelColor.setStroke()
        panel.stroke()

        // The line of sight: the viewer always looks at the middle of the screen.
        let middle = point(axes.up.x*0.5,axes.up.y*0.5)
        let dot = point(eyeDistance,eyeHeight)
        let sight = NSBezierPath()
        sight.move(to:dot)
        sight.line(to:middle)
        sight.setLineDash([5,4],count:2,phase:0)
        sight.lineWidth = 1.5
        NSColor.systemPink.setStroke()
        sight.stroke()

        let marker = NSBezierPath(ovalIn:NSRect(x:dot.x-7,y:dot.y-7,width:14,height:14))
        NSColor.systemPink.setFill(); marker.fill()
        NSColor.white.setStroke(); marker.lineWidth = 1.5; marker.stroke()

        // In the corner rather than in the room: the room is the grid's own
        // frame, so a caption placed there lands on whatever it overlaps.
        label("lid \(String(format:"%.0f",lidAngle))°",
              at:CGPoint(x:bounds.width-64,y:bounds.height-16),color:.secondaryLabelColor)
    }

    private func drawGrid() {
        let grid = NSBezierPath()
        for step in stride(from:0.5,through:reach,by:0.5) {
            grid.move(to:point(step,0)); grid.line(to:point(step,height))
        }
        for step in stride(from:0.5,through:height,by:0.5) {
            grid.move(to:point(0,step)); grid.line(to:point(reach,step))
        }
        grid.lineWidth = 1
        NSColor.tertiaryLabelColor.setStroke()
        grid.stroke()
        for step in stride(from:1.0,through:reach-0.2,by:1.0) { label("\(Int(step))",at:point(step,0.16)) }
        for step in stride(from:1.0,through:height-0.2,by:1.0) { label("\(Int(step))",at:point(0.18,step)) }
    }

    private func label(_ text: String, at point: CGPoint, color: NSColor = .tertiaryLabelColor) {
        (text as NSString).draw(at:NSPoint(x:point.x-5,y:point.y-6),
                                withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:9,weight:.regular),
                                                .foregroundColor:color])
    }

    // MARK: dragging

    override func mouseDown(with event: NSEvent) { moveTo(event) }
    override func mouseDragged(with event: NSEvent) { moveTo(event) }

    private func moveTo(_ event: NSEvent) {
        // The view *is* the room frame, so a pointer position is already a room
        // position: no rotation and no panel geometry involved.
        let local = convert(event.locationInWindow,from:nil)
        let clamped = CameraRig.clamped(height:Double((local.y-origin.y)/CGFloat(scale)),
                                        distance:Double((local.x-origin.x)/CGFloat(scale)))
        eyeDistance = clamped.distance
        eyeHeight = clamped.height
        onMove?(clamped.distance,clamped.height)
    }

    override func resetCursorRects() { addCursorRect(bounds,cursor:.openHand) }
}

/// Bridges the rig into SwiftUI, keeping the two numbers in whatever binding the
/// caller keeps them.
struct CameraRigRepresentable: NSViewRepresentable {
    @Binding var settings: MotionSettings
    var lidAngle: Double

    func makeNSView(context: Context) -> CameraRigView {
        let view = CameraRigView()
        view.eyeDistance = settings.eyeDistance
        view.eyeHeight = settings.eyeHeight
        view.lidAngle = lidAngle
        view.onMove = { distance, height in
            settings.eyeDistance = distance
            settings.eyeHeight = height
        }
        return view
    }

    func updateNSView(_ view: CameraRigView, context: Context) {
        if view.eyeDistance != settings.eyeDistance { view.eyeDistance = settings.eyeDistance }
        if view.eyeHeight != settings.eyeHeight { view.eyeHeight = settings.eyeHeight }
        view.lidAngle = lidAngle
        view.onMove = { distance, height in
            settings.eyeDistance = distance
            settings.eyeHeight = height
        }
    }
}
