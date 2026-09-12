import XCTest
@testable import Ajar

final class HingeTests: XCTestCase {
    func testCalibrationClampAndInvalidRange() {
        XCTAssertEqual(progress(angle:60,minAngle:70,maxAngle:120),0)
        XCTAssertEqual(progress(angle:95,minAngle:70,maxAngle:120),0.5)
        XCTAssertEqual(progress(angle:140,minAngle:70,maxAngle:120),1)
        XCTAssertEqual(progress(angle:90,minAngle:100,maxAngle:100),0)
        XCTAssertEqual(progress(angle:.nan,minAngle:70,maxAngle:120),0)
    }
    func testUnfilteredHoldAndReverseAreExact() {
        var filter = HingeFilter()
        let a = filter.update(raw:82.3,timestamp:1,timeConstant:0)
        let b = filter.update(raw:82.3,timestamp:1.01,timeConstant:0)
        let c = filter.update(raw:80.3,timestamp:1.02,timeConstant:0)
        XCTAssertEqual(a.filteredAngle,82.3)
        XCTAssertEqual(b.filteredAngle,a.filteredAngle)
        XCTAssertEqual(b.angularVelocity,0)
        XCTAssertEqual(c.filteredAngle,80.3)
        XCTAssertLessThan(c.angularVelocity,0)
    }
    func testFilterTimeConstantAndGapReset() {
        var filter = HingeFilter()
        _ = filter.update(raw:80,timestamp:1,timeConstant:0.01)
        let step = filter.update(raw:100,timestamp:1.01,timeConstant:0.01)
        XCTAssertEqual(step.filteredAngle,80+20*(1-exp(-1)),accuracy:0.00001)
        let gap = filter.update(raw:90,timestamp:3,timeConstant:0.01)
        XCTAssertEqual(gap.filteredAngle,90)
        XCTAssertEqual(gap.angularVelocity,0)
    }
}

final class TransitionTests: XCTestCase {
    func testMaskEndpointsAndDirection() {
        for curvature in [-2.0,0,2] {
            var settings = EffectSettings(); settings.curvature = curvature
            for x in [0.0,0.5,1] { for y in [0.0,0.5,1] {
                XCTAssertEqual(effectMask(x:x,y:y,progress:0,settings:settings),0,accuracy:1e-8)
                XCTAssertEqual(effectMask(x:x,y:y,progress:1,settings:settings),1,accuracy:1e-8)
            } }
            let left = effectMask(x:0.3,y:0.4,progress:0.45,settings:settings)
            settings.reversed = true
            XCTAssertEqual(left,effectMask(x:0.7,y:0.4,progress:0.45,settings:settings),accuracy:1e-8)
        }
    }
    func testMaskMonotonicAndSurfaceReversible() {
        let settings = EffectSettings()
        let values = (0...100).map { effectMask(x:0.5,y:0.4,progress:Double($0)/100,settings:settings) }
        for i in 1..<values.count { XCTAssertGreaterThanOrEqual(values[i],values[i-1]) }
        let held = transition(progress:0.4,settings:settings)
        _ = transition(progress:0.8,settings:settings)
        XCTAssertEqual(held,transition(progress:0.4,settings:settings))
        XCTAssertEqual(transition(progress:0,settings:settings).outgoingOpacity,1)
        XCTAssertEqual(transition(progress:1,settings:settings).incomingOpacity,1)
    }
}
