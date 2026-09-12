import XCTest
import SwiftUI
import AppKit
@testable import Ajar

/// The rig picture is an `NSView` inside a `ScrollView`, and a representable
/// with no intrinsic size and no frame gets whatever the scroll view proposes —
/// which was a few points, so the grid drew as a speck. This pins the size it is
/// laid out at, because the failure is invisible from the code that draws it.
final class SettingsLayoutTests: XCTestCase {
    func testRigDrawsAtItsStatedSizeInsideTheScrollingSettings() throws {
        let hosting = NSHostingView(rootView:SettingsView(lidAngle:{ 103 }))
        hosting.frame = NSRect(x:0,y:0,width:600,height:640)
        let window = NSWindow(contentRect:hosting.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        let rig = try XCTUnwrap(Self.firstRig(in:hosting),"the settings no longer contain the rig")
        XCTAssertEqual(rig.frame.height,340,accuracy:1)
        XCTAssertGreaterThan(rig.bounds.width,400)
        // The grid is drawn at one scale for the whole room, so a real picture
        // means grid squares big enough to aim a drag at.
        XCTAssertGreaterThan(rig.bounds.height,300)
    }

    private static func firstRig(in view: NSView) -> CameraRigView? {
        if let rig = view as? CameraRigView { return rig }
        for subview in view.subviews {
            if let found = firstRig(in:subview) { return found }
        }
        return nil
    }
}
