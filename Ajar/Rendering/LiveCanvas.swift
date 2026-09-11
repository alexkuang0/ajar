import Foundation

/// Geometry of the padded canvas that the live display capture is drawn into.
///
/// The captured display is the picture. Black padding goes above, left and right
/// — never below, because that edge is the hinge — so the picture has somewhere
/// to swing, and the blur has black to soften into at its border. At rest the
/// picture fills the frame exactly, so none of the padding is on screen.
///
/// Blur is a mip-like pyramid: each level is half the size of the one before and
/// carries a small blur at its own scale, which together add up to the effective
/// sigma ladder the static test surfaces use (0, 2, 5, 12, 24, 48 px on a 1000 px
/// picture). That costs one small blur per level instead of one 90 px kernel.
struct LiveCanvas: Equatable {
    static let padSideFraction = 0.20
    static let padTopFraction = 0.25
    static let levelCount = 6
    /// Effective Gaussian sigma per level, as a fraction of the picture height.
    static let sigmaFractions: [Double] = [0, 0.002, 0.005, 0.012, 0.024, 0.048]

    let pictureWidth: Int
    let pictureHeight: Int
    let padSide: Int
    let padTop: Int

    init(pictureWidth: Int, pictureHeight: Int) {
        let width = max(0, pictureWidth)
        let height = max(0, pictureHeight)
        var side = Int((Double(height)*Self.padSideFraction).rounded())
        var top = Int((Double(height)*Self.padTopFraction).rounded())
        // An even canvas keeps every pyramid level an exact 2:1 reduction.
        if (width + 2*side) % 2 != 0 { side += 1 }
        if (height + top) % 2 != 0 { top += 1 }
        self.pictureWidth = width
        self.pictureHeight = height
        self.padSide = side
        self.padTop = top
    }

    var canvasWidth: Int { pictureWidth + 2*padSide }
    var canvasHeight: Int { pictureHeight + padTop }
    var isEmpty: Bool { pictureWidth <= 0 || pictureHeight <= 0 }
    var pictureAspect: Double { pictureHeight > 0 ? Double(pictureWidth)/Double(pictureHeight) : 1 }
    /// Padding in picture-height units, which is what the shader works in, and
    /// what keeps it independent of the display's pixel size.
    var padSideUnits: Double { pictureHeight > 0 ? Double(padSide)/Double(pictureHeight) : 0 }
    var padTopUnits: Double { pictureHeight > 0 ? Double(padTop)/Double(pictureHeight) : 0 }
    /// Sigma scaling, so `maxBlur` keeps the meaning it has on the 1000 px test
    /// picture instead of changing with the display resolution.
    var sigmaScale: Double { Double(pictureHeight)/1000 }

    /// The picture's rect inside the canvas, in canvas uv.
    var pictureRect: SIMD4<Float> {
        guard canvasWidth > 0, canvasHeight > 0 else { return SIMD4(0,0,1,1) }
        return SIMD4(Float(padSide)/Float(canvasWidth),
                     Float(padTop)/Float(canvasHeight),
                     Float(pictureWidth)/Float(canvasWidth),
                     Float(pictureHeight)/Float(canvasHeight))
    }

    var levelSizes: [(width: Int, height: Int)] {
        var sizes: [(width: Int, height: Int)] = []
        var width = canvasWidth
        var height = canvasHeight
        for _ in 0..<Self.levelCount {
            sizes.append((width, height))
            width = max(2, width/2)
            height = max(2, height/2)
        }
        return sizes
    }

    /// Blur to apply at each pyramid level, in that level's own pixels. Level 0
    /// is the untouched canvas, so there are `levelCount - 1` entries.
    static func levelSigmas(pictureHeight: Int) -> [Double] {
        var sigmas: [Double] = []
        var previous = 0.0
        for level in 1..<levelCount {
            let target = sigmaFractions[level]*Double(pictureHeight)
            let contribution = (target*target - previous*previous).squareRoot()
            sigmas.append(contribution/Double(1 << level))
            previous = target
        }
        return sigmas
    }
}
