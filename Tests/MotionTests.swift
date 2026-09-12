import XCTest
@testable import Ajar

final class MotionTests: XCTestCase {
    private let rate = 120.0

    /// Feeds one angle for `seconds`, advancing the response clock.
    private func hold(_ response: inout MotionResponse, angle: Double, from time: Double,
                      seconds: Double, settings: MotionSettings) -> (MotionFrame, Double) {
        var now = time
        var frame = MotionFrame()
        for _ in 0..<max(1,Int(seconds*rate)) {
            now += 1/rate
            frame = response.update(angle:angle,timestamp:now,settings:settings)
        }
        return (frame,now)
    }

    private func peakBlur(travel: Double, settings: MotionSettings) -> Double {
        var response = MotionResponse()
        _ = response.update(angle:95,timestamp:0,settings:settings)
        var peak = 0.0
        var now = 0.0
        for _ in 0..<Int(0.6*rate) {
            now += 1/rate
            peak = max(peak,response.update(angle:95+travel,timestamp:now,settings:settings).blur)
        }
        return peak
    }

    func testOneDegreeReportIsInterpolatedAcrossDisplayFrames() {
        var response = MotionResponse(); let settings = MotionSettings()
        _ = response.update(angle:90,timestamp:0,settings:settings)
        let first = response.update(angle:91,timestamp:1.0/60,settings:settings)
        let next = response.update(angle:91,timestamp:2.0/60,settings:settings)
        XCTAssertGreaterThan(first.displayAngle,90)
        XCTAssertLessThan(first.displayAngle,91)
        XCTAssertGreaterThan(next.displayAngle,first.displayAngle)
        XCTAssertLessThan(next.displayAngle,91)
    }

    /// The second reported problem: a hard cap on the angle meant the animation
    /// stopped responding partway through a normal lid movement. Blur must grow
    /// with travel, keep growing past the nominal span, and never arrive at a
    /// value where more travel does nothing.
    func testBlurGrowsWithTravelAndNeverStopsResponding() {
        let settings = MotionSettings()
        let span = settings.blurSpan
        let samples = [0.25,0.5,1.0,2.0,4.0].map { peakBlur(travel:span*$0,settings:settings) }
        for (index,value) in samples.enumerated() {
            XCTAssertGreaterThan(value,0)
            XCTAssertLessThan(value,1,"the effect must never sit exactly at its ceiling")
            if index > 0 {
                XCTAssertGreaterThan(value,samples[index-1],
                                     "traveling \([0.5,1.0,2.0,4.0][index-1])x the span must still change the picture")
            }
        }
        // The nominal span is a shape, not a stop: it lands short of the ceiling
        // and later travel keeps contributing.
        XCTAssertEqual(samples[2],0.762,accuracy:0.02,"tanh(1) at the nominal span")
        XCTAssertGreaterThan(samples[4]-samples[3],0.01)
    }

    /// The point of the effect: the picture stays where the animation started
    /// and the display rotates away from it, so the tilt is the angle actually
    /// travelled — tilt a 50° lid and the picture sits at 50°, not at some
    /// smaller fraction of it. The blur is a rendering choice and has its own
    /// softer curve, but it must keep growing with travel as well.
    /// The side view drags the camera in the screen's own frame, and draws the
    /// dot with the same maths reversed. If those two disagreed the dot would not
    /// sit under the pointer, so the round trip is the contract.
    func testCameraRigRoundTripsThroughThePanelFrame() {
        for lidAngle in [0.0,45.0,90.0,111.0,150.0] {
            for height in [-0.5,0.0,0.75,1.5,2.4] {
                for distance in [0.6,1.0,2.2,4.5] {
                    let world = CameraRig.worldPosition(height:height,distance:distance,lidAngle:lidAngle)
                    let back = CameraRig.panelCoordinates(x:world.x,y:world.y,lidAngle:lidAngle)
                    XCTAssertEqual(back.height,height,accuracy:1e-9,"height round trip at \(lidAngle)°")
                    XCTAssertEqual(back.distance,distance,accuracy:1e-9,"distance round trip at \(lidAngle)°")
                }
            }
        }
    }

    /// The bug this replaced: the dot moved when the lid moved. Where the viewer
    /// sits is a room position, so it must not depend on the lid angle at all —
    /// while the screen-frame numbers the projection needs must depend on it,
    /// because the screen turns under a person who does not.
    func testTheViewerDoesNotMoveWithTheLid() {
        var settings = MotionSettings()
        settings.eyeDistance = 2.4
        settings.eyeHeight = 2.2
        // The stored position is the same number whatever the lid is doing.
        XCTAssertEqual(settings.eyeDistance,2.4)
        XCTAssertEqual(settings.eyeHeight,2.2)
        // What the renderer uses does change, and by a lot over a real lid range:
        var seen: [(height: Double, distance: Double)] = []
        for lid in [60.0,90.0,110.0,130.0,150.0] { seen.append(settings.panelCamera(atLidAngle:lid)) }
        XCTAssertGreaterThan(seen.map(\.height).max()!-seen.map(\.height).min()!,0.5,
                             "the eye's place in the screen's frame should move as the screen turns")
        XCTAssertGreaterThan(seen.map(\.distance).max()!-seen.map(\.distance).min()!,0.5)
        // And converting back gives the room position again, for every angle.
        for (index,lid) in [60.0,90.0,110.0,130.0,150.0].enumerated() {
            let room = CameraRig.worldPosition(height:seen[index].height,distance:seen[index].distance,lidAngle:lid)
            XCTAssertEqual(room.x,2.4,accuracy:1e-9,"room position drifted at \(lid)°")
            XCTAssertEqual(room.y,2.2,accuracy:1e-9)
        }
    }

    func testCameraRigClampsToTheDragRange() {
        let low = CameraRig.clamped(height:-99,distance:0)
        XCTAssertEqual(low.height,CameraRig.heightRange.lowerBound)
        XCTAssertEqual(low.distance,CameraRig.distanceRange.lowerBound)
        let high = CameraRig.clamped(height:99,distance:99)
        XCTAssertEqual(high.height,CameraRig.heightRange.upperBound)
        XCTAssertEqual(high.distance,CameraRig.distanceRange.upperBound)
    }

    /// Why the camera height is worth exposing at all: raising it keeps more of
    /// the picture's height on screen when the picture tips away. That is the
    /// "the shrinking is too much from my angle" complaint, as a number.
    func testRaisingTheCameraKeepsMoreOfThePictureHeight() {
        let hingeLevel = CameraRig.freeEdgeHeight(tilt:50,height:0,distance:2.2)
        let eyeLevel = CameraRig.freeEdgeHeight(tilt:50,height:1.5,distance:2.2)
        XCTAssertLessThan(hingeLevel,0.5,"from the hinge line a 50° tip leaves under half the picture")
        XCTAssertGreaterThan(eyeLevel,0.6,"from eye height it leaves considerably more")
        XCTAssertGreaterThan(eyeLevel,hingeLevel)
        for height in [0.0,1.5,2.8] {
            XCTAssertEqual(CameraRig.freeEdgeHeight(tilt:0,height:height,distance:2.2),1.0,accuracy:1e-12)
        }
    }

    func testTiltEqualsTheAngleActuallyTravelled() throws {
        let settings = MotionSettings()
        for travel in [20.0,50.0,80.0] {
            let blurred = peakBlur(travel:travel,settings:settings)
            XCTAssertGreaterThan(blurred,0)
        }
        for travel in [20.0,50.0,80.0] {
            var response = MotionResponse()
            _ = response.update(angle:80,timestamp:0,settings:settings)
            let (frame,_) = hold(&response,angle:80+travel,from:0,seconds:0.8,settings:settings)
            XCTAssertEqual(frame.ratio*MotionFrame.maximumTilt,travel,accuracy:0.8,
                           "a \(travel)° movement must render as a \(travel)° tilt")
            XCTAssertEqual(frame.signedDelta,travel,accuracy:0.8)
        }
        // Blur is monotonic in travel and never sits at its ceiling.
        let blurs = [10.0,30.0,60.0,120.0].map { peakBlur(travel:$0,settings:settings) }
        for index in 1..<blurs.count {
            XCTAssertGreaterThan(blurs[index],blurs[index-1],"more travel must mean more frost")
        }
        XCTAssertLessThan(blurs.last!,1.0,"the frost must never quite arrive")
    }

    func testHeldAngleCatchesUpAndRefocuses() {
        let settings = MotionSettings()
        let travel = settings.blurSpan   // the blur span is the reference point of the frost
        var response = MotionResponse()
        _ = response.update(angle:90,timestamp:0,settings:settings)
        let (peak,time) = hold(&response,angle:90+travel,from:0,seconds:0.6,settings:settings)
        XCTAssertEqual(peak.blur,0.762,accuracy:0.03,"tanh(1) at the blur span")
        // The tilt is not on that curve: it is the angle actually travelled.
        XCTAssertEqual(peak.ratio*MotionFrame.maximumTilt,travel,accuracy:0.6,"the tilt should be the real travel")
        XCTAssertEqual(peak.signedDelta,travel,accuracy:0.5)
        let (settled,_) = hold(&response,angle:90+travel,from:time,
                               seconds:settings.settleSeconds+1.5,settings:settings)
        XCTAssertLessThan(settled.blur,0.02)
        XCTAssertEqual(settled.anchorAngle,90+travel,accuracy:0.1)
    }

    func testReversingTravelBacksTheEffectOut() {
        let settings = MotionSettings()
        var response = MotionResponse()
        _ = response.update(angle:95,timestamp:0,settings:settings)
        let (out,time) = hold(&response,angle:95+settings.blurSpan,from:0,seconds:0.6,settings:settings)
        XCTAssertGreaterThan(out.blur,0.7)
        let (back,_) = hold(&response,angle:105,from:time,seconds:0.2,settings:settings)
        XCTAssertLessThan(back.blur,out.blur)
        XCTAssertLessThan(back.signedDelta,out.signedDelta)
    }

    func testSettleIsFrameRateIndependent() {
        let settings = MotionSettings()
        func blurAfterHalfSecond(sampleRate: Double) -> Double {
            var response = MotionResponse()
            _ = response.update(angle:100,timestamp:0,settings:settings)
            var now = 0.0
            var frame = MotionFrame()
            for _ in 0..<Int(sampleRate/2) {
                now += 1/sampleRate
                frame = response.update(angle:112.5,timestamp:now,settings:settings)
            }
            return frame.blur
        }
        // The same physical half-second should land in the same place whether the
        // reports arrive at 30 Hz or 120 Hz.
        XCTAssertEqual(blurAfterHalfSecond(sampleRate:30),
                       blurAfterHalfSecond(sampleRate:120),accuracy:0.06)
    }

    /// Feeds a time-varying angle, for modelling continuous movement and wobble.
    private func advance(_ response: inout MotionResponse, seconds: Double, from time: Double,
                         settings: MotionSettings, angle: (Double) -> Double) -> (MotionFrame, Double) {
        var now = time
        var frame = MotionFrame()
        for _ in 0..<max(1,Int(seconds*rate)) {
            now += 1/rate
            frame = response.update(angle:angle(now),timestamp:now,settings:settings)
        }
        return (frame,now)
    }

    func testSlowContinuousMovementStillAccumulatesTheEffect() {
        let settings = MotionSettings()
        var response = MotionResponse()
        _ = response.update(angle:100,timestamp:0,settings:settings)
        // 4 deg/s for 5 s: an unhurried but deliberate lid movement. The movement
        // gate must not mistake this for wobble or the effect would never build.
        let (frame,_) = advance(&response,seconds:5,from:0,settings:settings) { 100+4*$0 }
        XCTAssertEqual(frame.signedDelta,20,accuracy:1)
        XCTAssertGreaterThan(frame.blur,0.4,"slow continuous movement should still accumulate")
        // And it is still climbing rather than parked against a ceiling.
        let (later,_) = advance(&response,seconds:2,from:5,settings:settings) { 100+4*$0 }
        XCTAssertGreaterThan(later.blur,frame.blur)
    }

    /// The lid keeps trembling after you let go. That must not be mistaken for
    /// movement, or the catch-up would be postponed forever.
    func testWobbleIsNotMovementAndDoesNotDelayCatchUp() {
        let settings = MotionSettings()
        var response = MotionResponse()
        _ = response.update(angle:100,timestamp:0,settings:settings)
        let (moved,time) = advance(&response,seconds:0.6,from:0,settings:settings) { _ in 125 }
        XCTAssertGreaterThan(moved.blur,0.5)
        // Roughly 4 Hz, +/-0.4 deg: the sort of residual sway the hinge has.
        let (settled,_) = advance(&response,seconds:2.5,from:time,settings:settings) { 125+0.4*sin($0*25) }
        XCTAssertLessThan(settled.blur,0.05,"wobble should not keep resetting the still timer")
        XCTAssertEqual(settled.anchorAngle,125,accuracy:0.5)
    }

    func testWobbleFromRestNeverOpensTheEffect() {
        let settings = MotionSettings()
        var response = MotionResponse()
        _ = response.update(angle:100,timestamp:0,settings:settings)
        let (frame,_) = advance(&response,seconds:2,from:0,settings:settings) { 100+0.4*sin($0*25) }
        XCTAssertLessThan(frame.blur,0.05,"a slight wobble must not start the effect")
    }

    func testWholeScreenFieldDefocusesEverythingAndFollowsDirection() {
        let settings = MotionSettings()
        var frame = MotionFrame()
        frame.blur = 1; frame.ratio = 1
        var lowest = 1.0
        for xi in 0...10 { for yi in 0...10 {
            lowest = min(lowest,motionMask(x:Double(xi)/10,y:Double(yi)/10,frame:frame,settings:settings))
        } }
        // A whole-screen depth field never leaves part of the frame sharp.
        // The hinge end is only lightly blurred, but nothing is left sharp.
        XCTAssertGreaterThan(lowest,0.1)
        let nearTop = motionMask(x:0.5,y:0,frame:frame,settings:settings)
        let nearBottom = motionMask(x:0.5,y:1,frame:frame,settings:settings)
        XCTAssertNotEqual(nearTop,nearBottom,accuracy:0.05)
        var reversed = settings; reversed.reversed = true
        XCTAssertEqual(motionMask(x:0.5,y:0,frame:frame,settings:reversed),nearBottom,accuracy:1e-9)
        frame.blur = 0; frame.ratio = 0
        XCTAssertEqual(motionMask(x:0.5,y:0.5,frame:frame,settings:settings),0)
    }
}
