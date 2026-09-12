import CoreGraphics
import Foundation

/// One frame's worth of what Vision found: both pupils, in image pixels, plus
/// the head pose so unusable frames can be thrown away.
struct EyeDetection {
    var leftPupil: CGPoint
    var rightPupil: CGPoint
    var imageSize: CGSize
    /// Radians. A face turned or tilted away from the camera makes the pupils
    /// foreshorten, which reads as someone further away.
    var yaw: Double
    var roll: Double
}

/// Turns pupil positions into where the user's eyes are relative to the screen.
///
/// The camera is fixed to the lid, so it is rigidly attached to the screen's own
/// frame: its optical axis is the screen's normal and it sits one screen height
/// up the midline. That means the answer comes out directly in the two numbers
/// the projection already uses, and the lid angle never enters — the geometry is
/// the same whether the lid is open at 100° or 120°.
///
/// Both unknowns are assumptions rather than measurements, because macOS does
/// not expose a camera's focal length: the field of view is assumed (Apple's
/// FaceTime camera is about 70° horizontal) and so is the interpupillary
/// distance (63 mm is the adult average, and real people run 55–72 mm).
enum EyePositionEstimator {
    struct Assumptions: Equatable {
        var horizontalFieldOfView = 70.0     // degrees
        var interpupillaryDistance = 63.0    // millimetres
        var panelHeightMillimetres = 211.4   // from CGDisplayScreenSize
        /// Where the camera sits on the panel, in screen heights. The FaceTime
        /// camera is at the top edge, so one screen height up from the hinge.
        var cameraHeightOnPanel = 1.0
        /// Faces turned further than this are rejected.
        var maximumYaw = 15.0 * .pi/180
        var maximumRoll = 15.0 * .pi/180
    }

    struct Estimate: Equatable {
        var cameraHeight: Double       // screen heights above the hinge
        var viewDistance: Double       // screen heights in front of the screen
        var frames: Int
        /// Spread of the accepted frames, in screen heights. Large means either
        /// the user moved or the landmarks were poor.
        var spread: Double
        var note: String

        var confidence: Double {
            guard frames >= 3 else { return 0 }
            let byFrames = min(1,Double(frames)/20)
            let bySpread = max(0,1-spread/0.5)
            return min(byFrames,bySpread)
        }
    }

    enum Failure: LocalizedError {
        case notEnoughFrames(seen: Int, accepted: Int)
        case implausible(distance: Double)

        var errorDescription: String? {
            switch self {
            case .notEnoughFrames(let seen, let accepted):
                return "Could not read your eyes: \(seen) frames captured, \(accepted) usable. Face the screen straight on, in even light, and try again."
            case .implausible(let distance):
                return String(format:"The measurement came out at %.0f cm, which is not a sensible distance to a laptop. Try again with your face centred.",distance/10)
            }
        }
    }

    /// Pixels of focal length for an image of this width.
    static func focalLength(imageWidth: Double, fieldOfView: Double) -> Double {
        (imageWidth/2) / tan(fieldOfView/2 * .pi/180)
    }

    /// What one frame says, in screen heights.
    static func estimate(from detection: EyeDetection, assumptions: Assumptions) -> (height: Double, distance: Double)? {
        guard abs(detection.yaw) <= assumptions.maximumYaw,
              abs(detection.roll) <= assumptions.maximumRoll else { return nil }
        let separation = hypot(detection.rightPupil.x-detection.leftPupil.x,
                               detection.rightPupil.y-detection.leftPupil.y)
        guard separation > 6 else { return nil }
        let focal = focalLength(imageWidth:Double(detection.imageSize.width),fieldOfView:assumptions.horizontalFieldOfView)
        // Z = f * real separation / imaged separation, the pinhole range relation.
        let distanceMillimetres = focal * assumptions.interpupillaryDistance / Double(separation)
        // Vertical offset of the eyes from the optical axis, in the same units.
        let centreY = Double((detection.leftPupil.y+detection.rightPupil.y)/2)
        let imageCentreY = Double(detection.imageSize.height)/2
        let above = (imageCentreY-centreY)/focal * distanceMillimetres
        let eyeHeightMillimetres = assumptions.cameraHeightOnPanel*assumptions.panelHeightMillimetres + above
        return (height: eyeHeightMillimetres/assumptions.panelHeightMillimetres,
                distance: distanceMillimetres/assumptions.panelHeightMillimetres)
    }

    /// Medians across the frames that survive the pose gate.
    static func estimate(from detections: [EyeDetection], assumptions: Assumptions) -> Result<Estimate, Failure> {
        var heights: [Double] = [], distances: [Double] = []
        for detection in detections {
            guard let one = estimate(from:detection,assumptions:assumptions) else { continue }
            heights.append(one.height)
            distances.append(one.distance)
        }
        guard heights.count >= 3 else {
            return .failure(.notEnoughFrames(seen:detections.count,accepted:heights.count))
        }
        heights.sort(); distances.sort()
        let height = heights[heights.count/2]
        let distance = distances[distances.count/2]
        guard distance > 0.3, distance < 6 else { return .failure(.implausible(distance:distance*assumptions.panelHeightMillimetres)) }
        let spread = max(heights.last!-heights.first!, distances.last!-distances.first!)
        let note = String(format:"%d of %d frames · eyes ≈ %.0f cm up, %.0f cm back · spread %.0f cm",
                          heights.count, detections.count,
                          height*assumptions.panelHeightMillimetres/10,
                          distance*assumptions.panelHeightMillimetres/10,
                          spread*assumptions.panelHeightMillimetres/10)
        return .success(Estimate(cameraHeight:height,viewDistance:distance,
                                 frames:heights.count,spread:spread,note:note))
    }
}
