import XCTest
import Metal
@testable import Ajar

final class MetalTests: XCTestCase {
    /// The app stores the eye in room coordinates; these tests think in the
    /// screen's frame. This converts one to the other at a given lid angle.
    private func roomEye(panelHeight: Double, panelDistance: Double, lidAngle: Double) -> (x: Double, y: Double) {
        CameraRig.worldPosition(height:panelHeight,distance:panelDistance,lidAngle:lidAngle)
    }

    func testGPUFieldMatchesCPUAndFocusEndpointsHoldReverse() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf:root.appendingPathComponent("Ajar/Rendering/Shaders.metal"))
        let library = try device.makeLibrary(source:source,options:nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name:"fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name:"focusComposite")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor:descriptor)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let width = 32, height = 24
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false)
        desc.storageMode = .shared; desc.usage = [.renderTarget,.shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor:desc))
        func solid(_ rgba: [UInt8]) throws -> MTLTexture {
            let texture = try XCTUnwrap(device.makeTexture(descriptor:desc))
            let bytes = Array(repeating:rgba,count:width*height).flatMap { $0 }
            bytes.withUnsafeBytes { texture.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,withBytes:$0.baseAddress!,bytesPerRow:width*4) }
            return texture
        }
        let a = try solid([24,96,160,255]), b = try solid([192,112,48,255])
        func render(_ p: Double, settings: EffectSettings) throws -> [UInt8] {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
            var uniforms = MetalUniforms(progress:p,settings:settings,aspect:4.0/3.0)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms,length:MemoryLayout<MetalUniforms>.stride,index:0)
            encoder.setFragmentTextures(Array(repeating:a,count:6).map(Optional.some),range:0..<6)
            encoder.setFragmentTextures(Array(repeating:b,count:6).map(Optional.some),range:6..<12)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            var bytes = [UInt8](repeating:0,count:width*height*4)
            bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:width*4,from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
            return bytes
        }
        var settings = EffectSettings()
        XCTAssertEqual(Array(try render(0,settings:settings).prefix(4)),[24,96,160,255])
        XCTAssertEqual(Array(try render(1,settings:settings).prefix(4)),[192,112,48,255])
        let held = try render(0.4,settings:settings)
        XCTAssertEqual(held,try render(0.4,settings:settings))
        _ = try render(0.8,settings:settings)
        XCTAssertEqual(held,try render(0.4,settings:settings))
        settings.debugMask = true
        for reversed in [false,true] {
            settings.reversed = reversed
            let pixels = try render(0.45,settings:settings)
            for y in 0..<height { for x in 0..<width {
                let expected = effectMask(x:(Double(x)+0.5)/Double(width),y:(Double(y)+0.5)/Double(height),progress:0.45,settings:settings)*255
                XCTAssertEqual(Double(pixels[(y*width+x)*4]),expected,accuracy:1.1)
            } }
        }
    }

    /// The display rotates about the hinge at its bottom edge: the hinge line
    /// must not move, and the free edge must swing instead of staying pinned to
    /// the top of the frame.
    func testMotionTransformPivotsAtTheHingeEdge() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf:root.appendingPathComponent("Ajar/Rendering/Shaders.metal"))
        let library = try device.makeLibrary(source:source,options:nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name:"fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name:"focusComposite")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor:descriptor)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        // Same construction as the real surface: a picture with black padding
        // above, left and right, and none below because that edge is the hinge.
        let imageWidth = 160, imageHeight = 120, padSide = 20, padTop = 30
        let width = imageWidth+2*padSide, height = imageHeight+padTop
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false)
        desc.storageMode = .shared; desc.usage = [.renderTarget,.shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor:desc))
        let sourceTexture = try XCTUnwrap(device.makeTexture(descriptor:desc))
        // A bright picture with a faint row ramp, so padding and picture are both
        // unambiguous.
        var picture = [UInt8](repeating:0,count:width*height*4)
        for row in 0..<height { for column in 0..<width {
            let inPicture = row >= padTop && row < padTop+imageHeight
                && column >= padSide && column < padSide+imageWidth
            guard inPicture else { continue }
            let index = (row*width+column)*4
            picture[index] = 240; picture[index+1] = UInt8(200+(row-padTop)*40/imageHeight)
            picture[index+2] = 240; picture[index+3] = 255
        } }
        picture.withUnsafeBytes { sourceTexture.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,
                                                        withBytes:$0.baseAddress!,bytesPerRow:width*4) }
        var settings = MotionSettings()
        settings.maxBlur = 0 // isolate the geometry from the blur
        // These assertions describe the camera at the hinge line: from there the
        // free edge swings off the top quickly. The eye-height default argues the
        // other way and is covered by its own test below.
        let lid = 110.0
        let hingeEye = roomEye(panelHeight:0,panelDistance:2.2,lidAngle:lid)
        settings.eyeDistance = hingeEye.x
        settings.eyeHeight = hingeEye.y
        func render(ratio: Double, amount: Double, settings: MotionSettings) throws -> [UInt8] {
            var frame = MotionFrame(); frame.blur = amount; frame.ratio = ratio
            frame.displayAngle = lid
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
            var uniforms = MetalUniforms(frame:frame,settings:settings,aspect:4.0/3.0)
            uniforms.canvas = SIMD4(Float(padSide)/Float(imageHeight),
                                    Float(padSide)/Float(imageHeight),
                                    Float(padTop)/Float(imageHeight),0)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms,length:MemoryLayout<MetalUniforms>.stride,index:0)
            encoder.setFragmentTextures(Array(repeating:sourceTexture,count:6).map(Optional.some),range:0..<6)
            encoder.setFragmentTextures(Array(repeating:sourceTexture,count:6).map(Optional.some),range:6..<12)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            var bytes = [UInt8](repeating:0,count:width*height*4)
            bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:width*4,
                                                            from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
            return bytes
        }
        let column = width/2
        func lit(_ bytes: [UInt8],_ row: Int) -> Bool { Double(bytes[(row*width+column)*4]) > 128 }
        func topEdge(_ bytes: [UInt8]) -> Int { (0..<height).first { lit(bytes,$0) } ?? -1 }
        func bottomEdge(_ bytes: [UInt8]) -> Int { (0..<height).last { lit(bytes,$0) } ?? -1 }

        let rest = try render(ratio:0,amount:0,settings:settings)
        // 15° is the pose these assertions were written around, spelled in
        // degrees now that ratio means "tilt as a fraction of the maximum".
        // Negative ratio is the direction that recedes and reveals padding.
        let opening = try render(ratio:15/MotionFrame.maximumTilt,amount:1,settings:settings)
        let closing = try render(ratio:-15/MotionFrame.maximumTilt,amount:1,settings:settings)

        // At rest the picture fills the frame: no padding is visible anywhere, so
        // all four edges of the screen are the picture's own edges.
        XCTAssertEqual(topEdge(rest),0,"the picture should reach the top edge at rest")
        XCTAssertEqual(bottomEdge(rest),height-1,"the picture should reach the bottom edge at rest")
        XCTAssertGreaterThan(rest[(0*width+1)*4],60,"top-left corner should be picture, not padding")
        XCTAssertGreaterThan(rest[(0*width+width-2)*4],60,"top-right corner should be picture")
        // The hinge line is the pivot and must not travel in any pose.
        for pose in [opening,closing] {
            XCTAssertEqual(bottomEdge(pose),bottomEdge(rest),accuracy:2,"the hinge line moved")
        }
        // The free edge swings: tilting away slides the padding in from above,
        // tilting toward the viewer keeps the picture covering the frame.
        XCTAssertGreaterThan(topEdge(closing),8,"tilting away should reveal padding above")
        XCTAssertEqual(topEdge(opening),0,"tilting toward the viewer should still fill the frame")
        // The revealed padding is black rather than a smeared picture edge.
        XCTAssertLessThan(Double(closing[(0*width+column)*4]),20,"above a receding picture should be black")
        // Flipping the rotation flag flips both directions.
        var mirrored = settings; mirrored.reverseRotation = true
        XCTAssertGreaterThan(topEdge(try render(ratio:15/MotionFrame.maximumTilt,amount:1,settings:mirrored)),8)
        XCTAssertEqual(topEdge(try render(ratio:-15/MotionFrame.maximumTilt,amount:1,settings:mirrored)),0)

        // A swing far past the old clamp still has to recede rather than invert:
        // the pixels above the free edge are background, not a sample taken from
        // behind the hinge, which is what used to smear the hinge row upwards and
        // was the real reason the angle was clamped. 80° is the slider's maximum.
        for swing in [45.0,65.0,80.0] {
            // ratio is the tilt as a fraction of MotionFrame.maximumTilt, so
            // these are real travels of 45°, 65° and 80°.
            let forced = try render(ratio:-swing/MotionFrame.maximumTilt,amount:1,settings:settings)

            XCTAssertGreaterThan(topEdge(forced),8,"\(swing)° must still recede, never invert")
            XCTAssertEqual(bottomEdge(forced),bottomEdge(rest),accuracy:2,"the hinge line moved at \(swing)°")
            XCTAssertLessThan(Double(forced[(0*width+column)*4]),20,"above a receding picture should be black at \(swing)°")
        }
        // Receding further must actually recede further, not stall: this is the
        // property the clamp was destroying.
        let eye = roomEye(panelHeight:1.5,panelDistance:2.2,lidAngle:110)
        settings.eyeDistance = eye.x
        settings.eyeHeight = eye.y
        let shallow = try render(ratio:-15/MotionFrame.maximumTilt,amount:1,settings:settings)
        let deep = try render(ratio:-80/MotionFrame.maximumTilt,amount:1,settings:settings)
        XCTAssertGreaterThan(topEdge(deep),topEdge(shallow),"a bigger swing should push the free edge further down")
    }

    /// The default camera sits at eye height, which is the whole point of making
    /// it draggable: from there the picture keeps far more of its height, so a
    /// gentle tip does not collapse it and the padding only appears once the tip
    /// is real. Rendered through the same pipeline, not just arithmetic.
    func testEyeHeightCameraCollapsesLessThanHingeHeight() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf:root.appendingPathComponent("Ajar/Rendering/Shaders.metal"))
        let library = try device.makeLibrary(source:source,options:nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name:"fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name:"focusComposite")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor:descriptor)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let imageWidth = 160, imageHeight = 120, padSide = 20, padTop = 30
        let width = imageWidth+2*padSide, height = imageHeight+padTop
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false)
        desc.storageMode = .shared; desc.usage = [.renderTarget,.shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor:desc))
        let sourceTexture = try XCTUnwrap(device.makeTexture(descriptor:desc))
        var picture = [UInt8](repeating:0,count:width*height*4)
        for row in 0..<height { for column in 0..<width {
            let inPicture = row >= padTop && row < padTop+imageHeight && column >= padSide && column < padSide+imageWidth
            guard inPicture else { continue }
            let index = (row*width+column)*4
            picture[index] = 240; picture[index+1] = 240; picture[index+2] = 240; picture[index+3] = 255
        } }
        picture.withUnsafeBytes { sourceTexture.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,
                                                        withBytes:$0.baseAddress!,bytesPerRow:width*4) }
        func topEdge(tilt: Double, cameraHeight: Double) throws -> Int {
            var settings = MotionSettings()
            settings.maxBlur = 0
            let lid = 110.0
            let eye = roomEye(panelHeight:cameraHeight,panelDistance:2.2,lidAngle:lid)
            settings.eyeDistance = eye.x
            settings.eyeHeight = eye.y
            var frame = MotionFrame(); frame.blur = 1; frame.ratio = -tilt/MotionFrame.maximumTilt
            frame.displayAngle = lid
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = output
            pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
            var uniforms = MetalUniforms(frame:frame,settings:settings,aspect:Double(imageWidth)/Double(imageHeight))
            uniforms.canvas = SIMD4(Float(padSide)/Float(imageHeight),Float(padSide)/Float(imageHeight),Float(padTop)/Float(imageHeight),0)
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms,length:MemoryLayout<MetalUniforms>.stride,index:0)
            encoder.setFragmentTextures(Array(repeating:sourceTexture,count:6).map(Optional.some),range:0..<6)
            encoder.setFragmentTextures(Array(repeating:sourceTexture,count:6).map(Optional.some),range:6..<12)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            var bytes = [UInt8](repeating:0,count:width*height*4)
            bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:width*4,
                                                            from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
            let column = width/2
            return (0..<height).first { Double(bytes[($0*width+column)*4]) > 128 } ?? -1
        }
        // At eye height a gentle tip keeps the picture over the whole frame, and a
        // real tip finally brings the padding in — later than it would from the
        // hinge line, which is the complaint this default answers.
        let eyeGentle = try topEdge(tilt:15,cameraHeight:1.5)
        XCTAssertEqual(eyeGentle,0,"at eye height a 15° tip should not expose padding")
        let eyeReal = try topEdge(tilt:50,cameraHeight:1.5)
        XCTAssertGreaterThan(eyeReal,8,"by 50° it should")
        let hingeGentle = try topEdge(tilt:15,cameraHeight:0)
        XCTAssertGreaterThan(hingeGentle,eyeGentle,"the hinge-height camera loses the top edge sooner")
    }

    /// The band above the picture's free edge is not picture at all. With side
    /// padding in the canvas it was black by accident: the invalid sample was
    /// clamped horizontally into the black columns, which merely happen to exist.
    /// Take those columns away and a badly handled sample shows the picture's own
    /// edge smeared upwards instead of background — which is why this is decided
    /// by the denominator now rather than by the padding.
    func testPixelsAboveTheFreeEdgeAreBackgroundWithoutSidePadding() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let root = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf:root.appendingPathComponent("Ajar/Rendering/Shaders.metal"))
        let library = try device.makeLibrary(source:source,options:nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name:"fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name:"focusComposite")
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor:descriptor)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let imageWidth = 160, imageHeight = 120, padTop = 30
        let width = imageWidth, height = imageHeight+padTop
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:width,height:height,mipmapped:false)
        desc.storageMode = .shared; desc.usage = [.renderTarget,.shaderRead]
        let output = try XCTUnwrap(device.makeTexture(descriptor:desc))
        let sourceTexture = try XCTUnwrap(device.makeTexture(descriptor:desc))
        var picture = [UInt8](repeating:0,count:width*height*4)
        for row in padTop..<height { for column in 0..<width {
            let index = (row*width+column)*4
            picture[index] = 240; picture[index+1] = 240; picture[index+2] = 240; picture[index+3] = 255
        } }
        picture.withUnsafeBytes { sourceTexture.replace(region:MTLRegionMake2D(0,0,width,height),mipmapLevel:0,
                                                        withBytes:$0.baseAddress!,bytesPerRow:width*4) }
        var settings = MotionSettings()
        settings.maxBlur = 0
        var frame = MotionFrame(); frame.blur = 1; frame.ratio = -80/MotionFrame.maximumTilt
        frame.displayAngle = 110
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear; pass.colorAttachments[0].storeAction = .store
        let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor:pass))
        var uniforms = MetalUniforms(frame:frame,settings:settings,aspect:Double(imageWidth)/Double(imageHeight))
        uniforms.canvas = SIMD4(0,0,Float(padTop)/Float(imageHeight),0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms,length:MemoryLayout<MetalUniforms>.stride,index:0)
        encoder.setFragmentTextures(Array(repeating:sourceTexture,count:6).map(Optional.some),range:0..<6)
        encoder.setFragmentTextures(Array(repeating:sourceTexture,count:6).map(Optional.some),range:6..<12)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); encoder.endEncoding()
        command.commit(); command.waitUntilCompleted()
        XCTAssertNil(command.error)
        var bytes = [UInt8](repeating:0,count:width*height*4)
        bytes.withUnsafeMutableBytes { output.getBytes($0.baseAddress!,bytesPerRow:width*4,
                                                        from:MTLRegionMake2D(0,0,width,height),mipmapLevel:0) }
        for row in 0..<6 {
            for column in [0,width/4,width/2,width-1] {
                XCTAssertLessThan(Double(bytes[(row*width+column)*4]),40,
                                  "row \(row) column \(column) is above the free edge and must be background")
            }
        }
    }
}
