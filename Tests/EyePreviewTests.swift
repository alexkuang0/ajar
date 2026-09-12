import XCTest
import CoreGraphics
@testable import Ajar

/// The preview draws the camera image aspect-fit and then marks pupils given in
/// image pixels. If that mapping is wrong the markers land on someone's ears,
/// which is worse than not showing them at all, so it is pinned here.
final class EyePreviewTests: XCTestCase {
    func testImageIsFittedAndPointsLandOnIt() {
        let image = CGSize(width:1280,height:720)
        let bounds = CGSize(width:368,height:270)
        let rect = EyePreviewGeometry.fitted(imageSize:image,in:bounds)
        XCTAssertEqual(rect.width,368,accuracy:0.01)
        XCTAssertEqual(rect.height,207,accuracy:0.01)
        XCTAssertEqual(rect.minX,0,accuracy:0.01)
        XCTAssertEqual(rect.minY,31.5,accuracy:0.01)   // centred, letterboxed

        let middle = EyePreviewGeometry.viewPoint(CGPoint(x:640,y:360),imageSize:image,in:bounds)
        XCTAssertEqual(middle.x,bounds.width/2,accuracy:0.01)
        XCTAssertEqual(middle.y,bounds.height/2,accuracy:0.01)

        let corner = EyePreviewGeometry.viewPoint(CGPoint(x:0,y:0),imageSize:image,in:bounds)
        XCTAssertEqual(corner.x,rect.minX,accuracy:0.01)
        XCTAssertEqual(corner.y,rect.minY,accuracy:0.01)
    }

    func testNothingIsDrawnBeforeThereIsASize() {
        XCTAssertEqual(EyePreviewGeometry.fitted(imageSize:CGSize(width:0,height:0),
                                                 in:CGSize(width:300,height:200)),.zero)
        XCTAssertEqual(EyePreviewGeometry.viewPoint(.zero,
                                                    imageSize:CGSize(width:640,height:480),
                                                    in:.zero),.zero)
    }
}
