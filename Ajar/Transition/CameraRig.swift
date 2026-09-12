import Foundation

/// Where the camera sits, in the screen's own frame.
///
/// The camera is constrained to the plane through the screen's vertical
/// midline, so two numbers describe it: how far up the screen from the hinge,
/// and how far out along the screen's normal. Both are in screen heights, which
/// is also the unit the shader works in, and both are what the side view lets
/// you drag.
///
/// Drawing and dragging both go through here rather than each doing its own
/// trigonometry, so a pointer position and the dot it draws cannot disagree.
enum CameraRig {
    static let heightRange: ClosedRange<Double> = -1.0...2.8
    static let distanceRange: ClosedRange<Double> = 0.5...6.0

    /// With the panel at `lidAngle` (0° = flat on the deck, 90° = upright, as
    /// the hinge sensor reports it), the screen runs away from the viewer and
    /// up; its normal points back towards them.
    static func axes(lidAngle: Double) -> (up: (x: Double, y: Double), out: (x: Double, y: Double)) {
        let radians = lidAngle * .pi/180
        return (up: (cos(radians), sin(radians)), out: (sin(radians), -cos(radians)))
    }

    /// The camera in world coordinates: x out from the screen plane, y up from
    /// the hinge, origin at the hinge.
    static func worldPosition(height: Double, distance: Double, lidAngle: Double) -> (x: Double, y: Double) {
        let axes = axes(lidAngle:lidAngle)
        return (x: height*axes.up.x + distance*axes.out.x,
                y: height*axes.up.y + distance*axes.out.y)
    }

    /// The inverse, which is what a drag uses.
    static func panelCoordinates(x: Double, y: Double, lidAngle: Double) -> (height: Double, distance: Double) {
        let axes = axes(lidAngle:lidAngle)
        return (height: x*axes.up.x + y*axes.up.y,
                distance: x*axes.out.x + y*axes.out.y)
    }

    static func clamped(height: Double, distance: Double) -> (height: Double, distance: Double) {
        (height: min(max(height,heightRange.lowerBound),heightRange.upperBound),
         distance: min(max(distance,distanceRange.lowerBound),distanceRange.upperBound))
    }

    /// How much of the screen's height the picture's free edge reaches when it
    /// tips by `tilt`. This is the number the camera position controls: at hinge
    /// height a 50° tip leaves under half of it, at eye height far more.
    static func freeEdgeHeight(tilt: Double, height: Double, distance: Double) -> Double {
        let radians = tilt * .pi/180
        return (distance*cos(radians) + height*sin(radians)) / (distance + sin(radians))
    }
}
