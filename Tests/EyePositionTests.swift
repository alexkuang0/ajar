import XCTest
import CoreGraphics
@testable import Ajar

final class EffectPolicyTests: XCTestCase {
    private func conditions(setup: Bool = true, permission: Bool = true, display: Bool = true) -> EffectPolicy.Conditions {
        EffectPolicy.Conditions(setupComplete:setup,hasScreenCapturePermission:permission,builtInDisplayInUse:display)
    }

    func testEffectRunsOnlyWhenEverythingIsInPlace() {
        XCTAssertTrue(EffectPolicy.canEnable(conditions()))
        XCTAssertFalse(EffectPolicy.canEnable(conditions(setup:false)))
        XCTAssertFalse(EffectPolicy.canEnable(conditions(permission:false)))
        XCTAssertFalse(EffectPolicy.canEnable(conditions(display:false)))
        XCTAssertNil(EffectPolicy.reasonBlocked(conditions()),"nothing to explain when it can run")
    }

    /// Each blocked state names itself, because a toggle that does nothing reads
    /// as a bug rather than as a missing precondition.
    func testEachBlockedStateExplainsItself() {
        XCTAssertEqual(EffectPolicy.reasonBlocked(conditions(setup:false)),"Finish setup to use the effect…")
        XCTAssertEqual(EffectPolicy.reasonBlocked(conditions(display:false)),"Built-in display is not in use…")
        XCTAssertEqual(EffectPolicy.reasonBlocked(conditions(permission:false)),"Screen Recording permission needed…")
    }

    /// Setup first: a machine that has not been through the walkthrough should not
    /// be told about permissions it has not been asked for yet.
    func testSetupIsReportedBeforeThePermission() {
        XCTAssertEqual(EffectPolicy.reasonBlocked(conditions(setup:false,permission:false,display:false)),
                       "Finish setup to use the effect…")
    }

    /// Clamshell with an external monitor: there is no built-in panel among the
    /// active screens, so the overlay would have nothing to cover.
    func testThisMachineReportsItsBuiltInDisplay() {
        XCTAssertTrue(HingeCapability.builtInDisplayInUse,"the built-in panel is in use on this machine")
        XCTAssertNotNil(HingeCapability.builtInScreen)
        XCTAssertTrue(HingeCapability.displayDescription.contains("mm"))
    }
}

final class EffectSupervisorTests: XCTestCase {
    private func action(display: Bool, was: Bool, running: Bool = true,
                        enabled: Bool = true, setup: Bool = true) -> EffectSupervisor.Action {
        EffectSupervisor.action(builtInInUse:display,builtInWasInUse:was,overlayRunning:running,
                                effectEnabled:enabled,setupComplete:setup)
    }

    /// Closing the lid onto an external monitor: the effect was running, so it is
    /// brought down and the user is told.
    func testLosingTheBuiltInDisplayTurnsTheEffectOffAndSaysSo() {
        XCTAssertEqual(action(display:false,was:true),.disable(notify:true))
    }

    /// Nothing running, nothing to announce. Waking a sleeping MacBook in
    /// clamshell should not produce a notification about an effect nobody had on.
    func testLosingTheDisplayQuietlyWhenNothingWasRunning() {
        XCTAssertEqual(action(display:false,was:true,running:false),.none)
    }

    func testLosingTheDisplayBeforeSetupIsIgnored() {
        XCTAssertEqual(action(display:false,was:true,setup:false),.none)
    }

    /// Coming back: the effect is restored only if the user still wants it.
    func testTheEffectComesBackWhenTheDisplayDoes() {
        XCTAssertEqual(action(display:true,was:false,running:false,enabled:true),.enable)
        XCTAssertEqual(action(display:true,was:false,running:false,enabled:false),.none,
                       "a user who turned the effect off should not have it turned back on")
    }

    /// Repeated notifications about the same screen would be noise.
    func testNothingHappensWhenTheDisplayStateDidNotChange() {
        XCTAssertEqual(action(display:true,was:true),.none)
        XCTAssertEqual(action(display:true,was:true,running:false),.none)
    }
}

final class OnboardingStateTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName:"dev.kuang.ajar.tests")
        defaults.removePersistentDomain(forName:"dev.kuang.ajar.tests")
    }

    /// Completion is what the menu bar gate reads, so it has to be a stored fact
    /// rather than a session one.
    func testCompletionIsStored() {
        XCTAssertFalse(OnboardingWindowController(store:HingeStore(),defaults:defaults).hasCompletedBefore)
        defaults.set(true,forKey:"dev.kuang.ajar.onboarded")
        XCTAssertTrue(OnboardingWindowController(store:HingeStore(),defaults:defaults).hasCompletedBefore)
    }

    /// One page means one readiness rule, and it is the three things the effect
    /// needs — the camera is deliberately not one of them, because the viewer can
    /// be dragged into place by hand.
    func testReadinessNeedsSensorPermissionAndDisplay() {
        let ready = EffectPolicy.Conditions(setupComplete:true,hasScreenCapturePermission:true,builtInDisplayInUse:true)
        XCTAssertTrue(EffectPolicy.canEnable(ready))
        for broken in [EffectPolicy.Conditions(setupComplete:true,hasScreenCapturePermission:false,builtInDisplayInUse:true),
                       EffectPolicy.Conditions(setupComplete:true,hasScreenCapturePermission:true,builtInDisplayInUse:false)] {
            XCTAssertFalse(EffectPolicy.canEnable(broken))
        }
    }
}

final class EyePositionTests: XCTestCase {
    private let assumptions = EyePositionEstimator.Assumptions()

    /// Lights up a synthetic face: puts the pupils exactly where a pair of eyes
    /// at (height, distance) would land in the image, then checks the estimator
    /// recovers the position it was given.
    private func detection(height: Double, distance: Double, imageSize: CGSize = CGSize(width:1280,height:720),
                           yaw: Double = 0, roll: Double = 0, offsetX: Double = 0) -> EyeDetection {
        let panel = assumptions.panelHeightMillimetres
        let focal = EyePositionEstimator.focalLength(imageWidth:Double(imageSize.width),
                                                     fieldOfView:assumptions.horizontalFieldOfView)
        let distanceMM = distance*panel
        let aboveMM = (height-assumptions.cameraHeightOnPanel)*panel
        let separationPixels = focal*assumptions.interpupillaryDistance/distanceMM
        let centreY = Double(imageSize.height)/2 - aboveMM/distanceMM*focal
        let centreX = Double(imageSize.width)/2 + offsetX
        return EyeDetection(leftPupil:CGPoint(x:centreX-separationPixels/2,y:centreY),
                            rightPupil:CGPoint(x:centreX+separationPixels/2,y:centreY),
                            imageSize:imageSize,yaw:yaw,roll:roll)
    }

    func testRecoversAnEyePositionFromSyntheticPupils() throws {
        for height in [0.6,1.0,1.5,2.0] {
            for distance in [0.8,1.5,2.2,3.2] {
                let guess = try XCTUnwrap(EyePositionEstimator.estimate(
                    from:detection(height:height,distance:distance),assumptions:assumptions))
                XCTAssertEqual(guess.height,height,accuracy:1e-9,"height at \(height), \(distance)")
                XCTAssertEqual(guess.distance,distance,accuracy:1e-9,"distance at \(height), \(distance)")
            }
        }
    }

    /// A face turned away foreshortens the pupils, which reads as further away —
    /// so those frames are dropped rather than averaged in.
    func testRejectsTurnedAndTiltedFaces() {
        XCTAssertNil(EyePositionEstimator.estimate(from:detection(height:1.5,distance:2.2,yaw:0.5),assumptions:assumptions))
        XCTAssertNil(EyePositionEstimator.estimate(from:detection(height:1.5,distance:2.2,roll:-0.6),assumptions:assumptions))
        XCTAssertNotNil(EyePositionEstimator.estimate(from:detection(height:1.5,distance:2.2,yaw:0.1),assumptions:assumptions))
        // A sideways offset does not change either number: the model has no
        // horizontal camera offset, so it takes the distance and the height only.
        let centred = EyePositionEstimator.estimate(from:detection(height:1.3,distance:2.0),assumptions:assumptions)
        let shifted = EyePositionEstimator.estimate(from:detection(height:1.3,distance:2.0,offsetX:120),assumptions:assumptions)
        XCTAssertEqual(try XCTUnwrap(centred).distance,try XCTUnwrap(shifted).distance,accuracy:1e-9)
        XCTAssertEqual(try XCTUnwrap(centred).height,try XCTUnwrap(shifted).height,accuracy:1e-9)
    }

    func testAveragesFramesAndReportsSpread() throws {
        var frames: [EyeDetection] = []
        for index in 0..<12 {
            let jitter = Double(index % 3 - 1) * 0.03
            frames.append(detection(height:1.5+jitter,distance:2.2+jitter))
        }
        let estimate = try EyePositionEstimator.estimate(from:frames,assumptions:assumptions).get()
        XCTAssertEqual(estimate.cameraHeight,1.5,accuracy:0.02)
        XCTAssertEqual(estimate.viewDistance,2.2,accuracy:0.02)
        XCTAssertEqual(estimate.frames,12)
        XCTAssertGreaterThan(estimate.confidence,0.5)
        XCTAssertTrue(estimate.note.contains("cm"),"the note should speak in centimetres: \(estimate.note)")
    }

    func testRefusesWhenThereIsNothingToAverage() {
        let frames = (0..<8).map { _ in detection(height:1.5,distance:2.2,yaw:1.0) }
        switch EyePositionEstimator.estimate(from:frames,assumptions:assumptions) {
        case .success: XCTFail("turned faces should not produce an estimate")
        // localizedDescription, not the case name: LocalizedError is what the
        // settings window shows the user, so that is what the test should read.
        case .failure(let error): XCTAssertTrue(error.localizedDescription.contains("usable"),
                                               "unexpected wording: \(error.localizedDescription)")
        }
    }

    /// The assumption that costs the most is the lens, because macOS exposes no
    /// focal length. Quantified so the tradeoff is on the record rather than
    /// buried: a 10% error in the field of view moves the height by a small
    /// fraction of a screen height, because the bearing to a seated user is
    /// modest, and the distance by about the same 10%.
    func testSensitivityToTheAssumedFieldOfView() throws {
        let truth = detection(height:1.5,distance:2.2)
        var wrong = assumptions
        wrong.horizontalFieldOfView = assumptions.horizontalFieldOfView*0.9
        let guess = try XCTUnwrap(EyePositionEstimator.estimate(from:truth,assumptions:wrong))
        XCTAssertLessThan(abs(guess.height-1.5),0.15,"height should barely move")
        XCTAssertLessThan(abs(guess.distance-2.2),0.4,"distance takes the error more directly")
    }
}
