import XCTest
import Metal
@testable import Ajar

final class LiveCanvasTests: XCTestCase {
    func testPaddingAndLevelLadder() {
        let canvas = LiveCanvas(pictureWidth:1440,pictureHeight:932)
        XCTAssertEqual(canvas.canvasWidth % 2,0)
        XCTAssertEqual(canvas.canvasHeight % 2,0)
        XCTAssertEqual(canvas.padSide,186)      // 0.20 of the picture height
        XCTAssertEqual(canvas.padTop,233+1)     // 0.25, bumped to keep the height even
        // Padding in picture-height units is what the shader gets, so it does not
        // change when the display resolution does.
        XCTAssertEqual(canvas.padTopUnits,0.25,accuracy:0.01)
        XCTAssertEqual(canvas.padSideUnits,0.20,accuracy:0.01)
        // Level 0 is the sharp canvas, and each level is half the one before.
        let sizes = canvas.levelSizes
        XCTAssertEqual(sizes.count,LiveCanvas.levelCount)
        XCTAssertEqual(sizes.first?.width,canvas.canvasWidth)
        XCTAssertEqual(sizes[1].width,canvas.canvasWidth/2)
        XCTAssertEqual(sizes[1].height,canvas.canvasHeight/2)
        // Effective sigma per level must keep growing, so more mask really is
        // more blur.
        let sigmas = LiveCanvas.levelSigmas(pictureHeight:canvas.pictureHeight)
        XCTAssertEqual(sigmas.count,LiveCanvas.levelCount-1)
        for (index,sigma) in sigmas.enumerated() {
            XCTAssertGreaterThan(sigma,0,"level \(index+1) must add blur")
            if index > 0 { XCTAssertGreaterThan(sigma,sigmas[index-1]*0.8) }
        }
    }

    func testPictureRectSitsBelowTheTopPadding() {
        let canvas = LiveCanvas(pictureWidth:1440,pictureHeight:932)
        let rect = canvas.pictureRect
        // Canvas v runs from the top padding down to the hinge, and the captured
        // display's own first row is the top of the screen, so the picture starts
        // below the padding and reaches the bottom edge of the canvas.
        XCTAssertEqual(rect.y,Float(canvas.padTop)/Float(canvas.canvasHeight),accuracy:0.0001)
        XCTAssertEqual(rect.y+rect.w,1.0,accuracy:0.0001)
        XCTAssertEqual(rect.x,Float(canvas.padSide)/Float(canvas.canvasWidth),accuracy:0.0001)
        XCTAssertEqual(rect.x*2+rect.z,1.0,accuracy:0.0001)
    }

    func testMaxBlurIsRescaledWithTheDisplay() {
        var settings = MotionSettings()
        settings.maxBlur = 32
        // The in-window preview keeps its own surface and stays opaque.
        let small = MetalUniforms(frame:MotionFrame(),settings:settings,aspect:1.6)
        let laptop = MetalUniforms(liveFrame:MotionFrame(),settings:settings,frameAspect:1.545,
                                   pictureAspect:1.545,canvas:LiveCanvas(pictureWidth:1440,pictureHeight:932))
        // 32 sigma on the test picture stays 32 sigma relative to the picture,
        // instead of silently becoming a third of the effect on a laptop panel.
        XCTAssertEqual(small.effect.x,32,accuracy:0.001)
        XCTAssertEqual(laptop.effect.x,32*0.932,accuracy:0.001)
        XCTAssertEqual(small.canvas.w,0,"the in-window preview stays opaque")
        XCTAssertEqual(laptop.canvas.w,1,"the overlay fades in with the mask")
    }

    /// End to end through the real Metal pipeline: fill the padded canvas from a
    /// captured-style frame, build the pyramid, composite it as an overlay.
    func testLiveOverlayPipelineKeepsOrientationAndFadesIn() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let pictureWidth = 160, pictureHeight = 100
        var settings = RenderSettings()
        settings.motion.maxBlur = 32
        settings.motion.overlayFadeStart = 0.10
        settings.motion.overlayFadeEnd = 0.45
        let renderer = try LiveTransitionRenderer(device:device,store:HingeStore(),
                                                  capture:LiveScreenCapture(),settings:settings)
        // A source with an unmistakable top and bottom: the real capture has the
        // screen's top row first in memory.
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:pictureWidth,height:pictureHeight,mipmapped:false)
        sourceDescriptor.usage = [.shaderRead]
        sourceDescriptor.storageMode = .shared
        let source = try XCTUnwrap(device.makeTexture(descriptor:sourceDescriptor))
        var sourcePixels = [UInt8](repeating:0,count:pictureWidth*pictureHeight*4)
        for row in 0..<pictureHeight { for column in 0..<pictureWidth {
            let index = (row*pictureWidth+column)*4
            let red = row < 5, blue = row >= pictureHeight-5
            sourcePixels[index] = red ? 255 : 0
            sourcePixels[index+1] = (red || blue) ? 0 : 255
            sourcePixels[index+2] = blue ? 255 : 0
            sourcePixels[index+3] = 255
        } }
        sourcePixels.withUnsafeBytes { source.replace(region:MTLRegionMake2D(0,0,pictureWidth,pictureHeight),
                                                      mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:pictureWidth*4) }
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(renderer.encodeFill(sourceTexture:source,command:command))
        renderer.encodePyramid(command:command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        let canvas = renderer.canvas
        let level0 = try readback(renderer.levels[0],queue:queue)
        func canvasPixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
            let index = (y*canvas.canvasWidth+x)*4
            return Array(bytes[index..<index+4])
        }
        let firstPictureRow = canvas.padTop, lastPictureRow = canvas.canvasHeight-1
        let middleColumn = canvas.canvasWidth/2
        // Padding is black; the picture's first row is the captured screen's top
        // row (red) and its last row is the hinge (blue). If the two ever swap,
        // the whole overlay is upside down.
        XCTAssertEqual(canvasPixel(level0,canvas.canvasWidth/2,5).prefix(3),[0,0,0])
        XCTAssertEqual(canvasPixel(level0,5,canvas.canvasHeight/2).prefix(3),[0,0,0])
        let top = canvasPixel(level0,middleColumn,firstPictureRow)
        let hinge = canvasPixel(level0,middleColumn,lastPictureRow)
        XCTAssertGreaterThan(Int(top[0]),200,"picture top should be the screen's top row")
        XCTAssertGreaterThan(Int(hinge[2]),200,"picture bottom should be the hinge row")
        // The padded border must blur into the picture: at the heaviest level a
        // texel that straddles the padding and the picture is no longer black,
        // while the same spot is pure black in the sharp canvas.
        let heavy = try readback(renderer.levels[LiveCanvas.levelCount-1],queue:queue)
        let level = canvas.levelSizes[LiveCanvas.levelCount-1]
        let straddling = ((level.width/6)*1+level.width/2)*4 // first row, just right of the padding
        XCTAssertGreaterThan(Int(max(heavy[straddling],heavy[straddling+1],heavy[straddling+2])),0,
                             "the heaviest level should smear the picture into the padding")
        XCTAssertEqual(canvasPixel(level0,canvas.canvasWidth/4,canvas.padTop/3).prefix(3),[0,0,0],
                       "the sharp canvas still has a hard padding edge")

        // Composite: at rest the overlay is invisible; with the effect on it is
        // opaque at the free edge and still faint near the hinge.
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:pictureWidth,height:pictureHeight,mipmapped:false)
        outputDescriptor.usage = [.renderTarget,.shaderRead]
        outputDescriptor.storageMode = .shared
        let output = try XCTUnwrap(device.makeTexture(descriptor:outputDescriptor))
        func composite(blur: Double, ratio: Double) throws -> [UInt8] {
            var frame = MotionFrame(); frame.blur = blur; frame.ratio = ratio
            frame.displayAngle = 110   // the eye's place in the screen's frame depends on this
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
            pass.colorAttachments[0].storeAction = .store
            XCTAssertTrue(renderer.encodeComposite(descriptor:pass,
                                                   drawableSize:CGSize(width:pictureWidth,height:pictureHeight),
                                                   frame:frame,draw:true,command:command))
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            var bytes = [UInt8](repeating:0,count:pictureWidth*pictureHeight*4)
            bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:pictureWidth*4,from:MTLRegionMake2D(0,0,pictureWidth,pictureHeight),mipmapLevel:0) }
            return bytes
        }
        func alpha(_ bytes: [UInt8], _ x: Int, _ y: Int) -> Int {
            Int(bytes[(y*pictureWidth+x)*4+3])
        }
        let rest = try composite(blur:0,ratio:0)
        for y in stride(from:0,to:pictureHeight,by:9) { XCTAssertEqual(alpha(rest,pictureWidth/2,y),0,"at rest the overlay must be invisible") }
        // Negative ratio swings the picture's free edge down and pulls the black
        // padding in from above; 15° is an ordinary reading pose.
        let tilted = try composite(blur:1,ratio: -15/MotionFrame.maximumTilt)
        XCTAssertGreaterThan(alpha(tilted,pictureWidth/2,4),250,"the free edge is fully covered")
        XCTAssertLessThan(alpha(tilted,pictureWidth/2,pictureHeight-4),60,"the hinge end stays mostly transparent")
        XCTAssertGreaterThan(alpha(tilted,pictureWidth/2,4),alpha(tilted,pictureWidth/2,pictureHeight-4))
        // Above the free edge the padding has swung in: black, and opaque. Not
        // exactly zero, because the padded border is blurred along with the
        // picture rather than cutting.
        XCTAssertEqual(alpha(tilted,pictureWidth/2,0),255)
        for channel in tilted[0..<3] { XCTAssertLessThan(Int(channel),12) }
    }

    /// The default fade band must not leave the overlay see-through once the
    /// effect is real: a translucent lower half lets the original, unmoved screen
    /// show through it, which reads as a rendering fault rather than as depth.
    /// At rest it must still be completely invisible.
    func testLiveOverlayIsOpaqueAtTheHingeOnceTheEffectIsReal() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let width = 64, height = 40
        let settings = RenderSettings() // defaults under test; no overrides
        XCTAssertEqual(settings.motion.overlayFadeStart,0)
        XCTAssertLessThanOrEqual(settings.motion.overlayFadeEnd,0.05)
        let renderer = try LiveTransitionRenderer(device:device,store:HingeStore(),
                                                  capture:LiveScreenCapture(),settings:settings)
        let sourceDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false)
        sourceDescriptor.usage = [.shaderRead]
        sourceDescriptor.storageMode = .shared
        let source = try XCTUnwrap(device.makeTexture(descriptor:sourceDescriptor))
        let flat = [UInt8](repeating:110,count:width*height*4)
        flat.withUnsafeBytes { source.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,
                                              withBytes:$0.baseAddress!,bytesPerRow:width*4) }
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        XCTAssertTrue(renderer.encodeFill(sourceTexture:source,command:command))
        renderer.encodePyramid(command:command)
        command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.bgra8Unorm,width:width,height:height,mipmapped:false)
        outputDescriptor.usage = [.renderTarget,.shaderRead]
        outputDescriptor.storageMode = .shared
        let output = try XCTUnwrap(device.makeTexture(descriptor:outputDescriptor))
        func alpha(blur: Double) throws -> Int {
            var frame = MotionFrame(); frame.blur = blur; frame.ratio = 0
            frame.displayAngle = 110
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
            pass.colorAttachments[0].storeAction = .store
            XCTAssertTrue(renderer.encodeComposite(descriptor:pass,drawableSize:CGSize(width:width,height:height),
                                                   frame:frame,draw:true,command:command))
            command.commit(); command.waitUntilCompleted()
            var bytes = [UInt8](repeating:0,count:width*height*4)
            bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:width*4,
                                                            from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
            // Bottom row of the frame is the hinge line.
            return Int(bytes[((height-2)*width+width/2)*4+3])
        }
        XCTAssertEqual(try alpha(blur:0),0,"the overlay must vanish at rest")
        XCTAssertEqual(try alpha(blur:1),255,"the hinge end must be covered once the effect is real")
    }

    private func readback(_ texture: MTLTexture, queue: MTLCommandQueue) throws -> [UInt8] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:texture.pixelFormat,width:texture.width,height:texture.height,mipmapped:false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        let read = try XCTUnwrap(texture.device.makeTexture(descriptor:descriptor))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let blit = try XCTUnwrap(command.makeBlitCommandEncoder())
        blit.copy(from:texture,sourceSlice:0,sourceLevel:0,sourceOrigin:MTLOrigin(x:0,y:0,z:0),
                  sourceSize:MTLSize(width:texture.width,height:texture.height,depth:1),
                  to:read,destinationSlice:0,destinationLevel:0,destinationOrigin:MTLOrigin(x:0,y:0,z:0))
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        var bytes = [UInt8](repeating:0,count:texture.width*texture.height*4)
        bytes.withUnsafeMutableBytes { read.getBytes($0.baseAddress!,bytesPerRow:texture.width*4,
                                                      from:MTLRegionMake2D(0,0,texture.width,texture.height),mipmapLevel:0) }
        return bytes
    }
}
