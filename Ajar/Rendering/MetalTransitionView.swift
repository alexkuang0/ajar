import AppKit
import SwiftUI
import MetalKit
import MetalPerformanceShaders

struct MetalUniforms {
    var field: SIMD4<Float>
    var effect: SIMD4<Float>
    var look: SIMD4<Float>
    var geometry: SIMD4<Float>
    var motion: SIMD4<Float> = .zero // motion mode, effect strength, signed travel ratio, gradient mode
    var canvas: SIMD4<Float> = .zero // padding left, right, top in picture-height units
    init(progress: Double, settings: EffectSettings, aspect: Double) {
        field = SIMD4(Float(progress),Float(settings.position),Float(settings.curvature),Float(settings.softness))
        effect = SIMD4(Float(settings.maxBlur),Float(settings.perspective),Float(settings.scale),Float(settings.crossfadeWidth))
        look = SIMD4(settings.reversed ? 1:0,settings.debugMask ? 1:0,Float(settings.luminance),Float(settings.contrast))
        geometry = SIMD4(Float(aspect),Float(1024.0/768.0),0,0)
    }
    init(frame: MotionFrame, settings: MotionSettings, aspect: Double) {
        // field.x carries the camera height for the motion path; the curvature
        // and softness in z/w belong to the hinge-sweep field. The eye is stored
        // in room coordinates, so convert it into the screen's frame for this
        // frame's angle — the viewer stays put while the screen turns.
        let camera = settings.panelCamera(atLidAngle:frame.displayAngle)
        field = SIMD4(Float(camera.height),0,Float(settings.curvature),Float(settings.softness))
        // Motion path: effect = (max blur, max tilt degrees, spare, spare)
        effect = SIMD4(Float(settings.maxBlur),Float(MotionFrame.maximumTilt),0,1)
        look = SIMD4(settings.reversed ? 1:0,settings.debugMask ? 1:0,0.015,0.02)
        // geometry = (frame aspect, source aspect, reverse rotation, view distance)
        geometry = SIMD4(Float(aspect),Float(SurfaceTextures.aspect),settings.reverseRotation ? 1:0,Float(camera.distance))
        motion = SIMD4(1,Float(frame.blur),Float(frame.ratio),settings.field == .gradient ? 1:0)
        canvas = SIMD4(Float(SurfaceTextures.padSide),Float(SurfaceTextures.padSide),Float(SurfaceTextures.padTop),0)
    }
    /// Live-screen variant. Same field and geometry, but the source is the
    /// captured display inside `canvas`, the blur is scaled to the display's
    /// pixel height, and `canvas.w` turns on overlay alpha: the window is
    /// transparent until the mask is large enough to hide the copy underneath,
    /// so at rest the real screen (and its cursor) shows through untouched.
    init(liveFrame frame: MotionFrame, settings: MotionSettings, frameAspect: Double,
         pictureAspect: Double, canvas: LiveCanvas) {
        // The eye is fixed in the room; the screen turns under it, so its place
        // in the screen's frame is recomputed for this frame's angle.
        let camera = settings.panelCamera(atLidAngle:frame.displayAngle)
        field = SIMD4(Float(camera.height),0,Float(settings.curvature),Float(settings.softness))
        effect = SIMD4(Float(settings.maxBlur*canvas.sigmaScale),Float(MotionFrame.maximumTilt),
                       Float(settings.overlayFadeStart),Float(settings.overlayFadeEnd))
        look = SIMD4(settings.reversed ? 1:0,settings.debugMask ? 1:0,0.015,0.02)
        geometry = SIMD4(Float(frameAspect),Float(pictureAspect),settings.reverseRotation ? 1:0,Float(camera.distance))
        motion = SIMD4(1,Float(frame.blur),Float(frame.ratio),settings.field == .gradient ? 1:0)
        self.canvas = SIMD4(Float(canvas.padSideUnits),Float(canvas.padSideUnits),Float(canvas.padTopUnits),1)
    }
}

final class MetalRenderer: NSObject, MTKViewDelegate {
    let store: HingeStore
    var settings: RenderSettings
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let outgoing: [MTLTexture]
    private let incoming: [MTLTexture]
    private let inFlight = DispatchSemaphore(value: 3)
    private var reportedError = false
    private var driver = MotionDriver()

    init(device: MTLDevice, store: HingeStore, settings: RenderSettings) throws {
        self.store = store; self.settings = settings
        guard let queue = device.makeCommandQueue() else { throw SensorError(message:"Metal command queue unavailable") }
        commandQueue = queue
        // Runtime compilation allows this playground to build with Command Line
        // Tools even when the optional offline Metal compiler is not installed.
        let url = Bundle.main.url(forResource:"Shaders",withExtension:"metal") ?? Bundle.module.url(forResource:"Shaders",withExtension:"metal")
        guard let url else { throw SensorError(message:"Missing Shaders.metal resource") }
        let library = try device.makeLibrary(source:String(contentsOf:url),options:nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name:"fullscreen")
        descriptor.fragmentFunction = library.makeFunction(name:"focusComposite")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipeline = try device.makeRenderPipelineState(descriptor:descriptor)
        outgoing = try Self.makeLevels(device:device,queue:queue,incoming:false)
        incoming = try Self.makeLevels(device:device,queue:queue,incoming:true)
        super.init()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard inFlight.wait(timeout:.now()) == .success else { return }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = commandQueue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor:pass) else { inFlight.signal(); return }
        let state = store.snapshot()
        let p = state.sample.map { progress(angle:$0.filteredAngle,minAngle:settings.minAngle,maxAngle:settings.maxAngle) } ?? 0
        let aspect = Double(view.drawableSize.width/max(1,view.drawableSize.height))
        var uniforms = MetalUniforms(progress:p,settings:settings.effect,aspect:aspect)
        if settings.mode == .motion {
            let frame = driver.frame(sample:state.sample,settings:settings.motion,
                                     token:MotionDriver.Token(reset:settings.responseReset,mode:settings.mode))
            uniforms = MetalUniforms(frame:frame,settings:settings.motion,aspect:aspect)
            PerformanceMetrics.shared.motion(frame)
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&uniforms,length:MemoryLayout<MetalUniforms>.stride,index:0)
        encoder.setFragmentTextures(outgoing.map(Optional.some),range:0..<6)
        encoder.setFragmentTextures(incoming.map(Optional.some),range:6..<12)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        encoder.endEncoding()
        command.present(drawable)
        command.addCompletedHandler { [weak self, inFlight] buffer in
            inFlight.signal()
            let gpuMs = max(0,buffer.gpuEndTime-buffer.gpuStartTime)*1000
            DispatchQueue.main.async {
                PerformanceMetrics.shared.gpu(milliseconds:gpuMs)
                if let error = buffer.error, self?.reportedError == false {
                    self?.reportedError = true
                    NSLog("Ajar Metal command failed: %@",error.localizedDescription)
                }
            }
        }
        command.commit()
        PerformanceMetrics.shared.frame(sampleTimestamp:state.sample?.timestamp)
    }
    private static func makeLevels(device: MTLDevice, queue: MTLCommandQueue, incoming: Bool) throws -> [MTLTexture] {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:SurfaceTextures.width,height:SurfaceTextures.height,mipmapped:false)
        descriptor.usage = [.shaderRead,.shaderWrite]; descriptor.storageMode = .shared
        guard let source = device.makeTexture(descriptor:descriptor) else { throw SensorError(message:"Cannot allocate source texture") }
        let pixels = SurfaceTextures.pixels(incoming:incoming)
        pixels.withUnsafeBytes { ptr in
            source.replace(region:MTLRegionMake2D(0,0,SurfaceTextures.width,SurfaceTextures.height),
                           mipmapLevel:0,withBytes:ptr.baseAddress!,bytesPerRow:SurfaceTextures.width*4)
        }
        var levels = [source]
        guard let command = queue.makeCommandBuffer() else { throw SensorError(message:"Cannot precompute blur levels") }
        descriptor.storageMode = .private
        for sigma: Float in [2,5,12,24,48] {
            guard let texture = device.makeTexture(descriptor:descriptor) else { throw SensorError(message:"Cannot allocate blur texture") }
            let blur = MPSImageGaussianBlur(device:device,sigma:sigma)
            blur.edgeMode = .clamp
            blur.encode(commandBuffer:command,sourceTexture:source,destinationTexture:texture)
            levels.append(texture)
        }
        command.commit(); command.waitUntilCompleted()
        if let error = command.error { throw error }
        return levels
    }
}

struct MetalTransitionView: NSViewRepresentable {
    let store: HingeStore
    let settings: RenderSettings
    final class Coordinator { var renderer: MetalRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice() else { return errorView("Metal unavailable. Select Tracking or Spatial mask.") }
        do {
            let renderer = try MetalRenderer(device:device,store:store,settings:settings)
            context.coordinator.renderer = renderer
            let view = MTKView(frame:.zero,device:device)
            view.colorPixelFormat = .bgra8Unorm
            view.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
            view.enableSetNeedsDisplay = false; view.isPaused = false
            view.delegate = renderer
            view.setAccessibilityLabel("Hinge-controlled progressive focus transition")
            return view
        } catch { return errorView(error.localizedDescription) }
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.renderer?.settings = settings }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { (view as? MTKView)?.isPaused = true; (view as? MTKView)?.delegate = nil; coordinator.renderer = nil }
    private func errorView(_ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString:"Metal initialization failed:\n\(text)")
        field.textColor = .systemOrange
        return field
    }
}
