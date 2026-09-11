import AppKit
import CoreVideo
import MetalKit
import MetalPerformanceShaders
import SwiftUI

/// Draws the live screen through the same hinge-driven focus pipeline as the
/// in-window preview.
///
/// Per display frame: copy the newest captured frame into the padded canvas,
/// rebuild the small blur pyramid from it, then run the shared composite shader.
/// The canvas and the pyramid are rebuilt every frame, so nothing about the
/// picture is cached across frames — only the pipeline objects are.
final class LiveTransitionRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let fillPipeline: MTLRenderPipelineState
    private let reducePipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let store: HingeStore
    private let capture: LiveScreenCapture
    var settings: RenderSettings

    private var textureCache: CVMetalTextureCache?
    /// Level 0 is the padded canvas; 1…5 are the blurred pyramid above it.
    private(set) var levels: [MTLTexture] = []
    private var reduced: [MTLTexture] = []
    private var blurs: [MPSImageGaussianBlur] = []
    private(set) var canvas = LiveCanvas(pictureWidth:0,pictureHeight:0)
    private var driver = MotionDriver()
    private let inFlight = DispatchSemaphore(value:3)
    private var reportedError = false
    private var lastFrame = MotionFrame()

    init(device: MTLDevice, store: HingeStore, capture: LiveScreenCapture, settings: RenderSettings) throws {
        self.device = device
        self.store = store
        self.capture = capture
        self.settings = settings
        guard let queue = device.makeCommandQueue() else { throw SensorError(message:"Metal command queue unavailable") }
        self.queue = queue
        let url = Bundle.main.url(forResource:"Shaders",withExtension:"metal") ?? Bundle.module.url(forResource:"Shaders",withExtension:"metal")
        guard let url else { throw SensorError(message:"Missing Shaders.metal resource") }
        let library = try device.makeLibrary(source:String(contentsOf:url),options:nil)
        func pipeline(_ fragment: String, format: MTLPixelFormat = .rgba8Unorm) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name:"fullscreen")
            descriptor.fragmentFunction = library.makeFunction(name:fragment)
            descriptor.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor:descriptor)
        }
        fillPipeline = try pipeline("canvasFill")
        reducePipeline = try pipeline("downscale")
        compositePipeline = try pipeline("focusComposite", format:.bgra8Unorm)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault,nil,device,nil,&cache)
        textureCache = cache
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard inFlight.wait(timeout:.now()) == .success else { PerformanceMetrics.shared.liveSkippedFrame(); return }
        // Composite at the captured pixel size and let the window server scale
        // the result to the panel. The sharp end of the field is the transparent
        // end, so the upscale costs nothing visible and saves 4x the fill the
        // composite would otherwise pay on a 2x display.
        if canvas.pictureWidth > 0, view.drawableSize != CGSize(width:canvas.pictureWidth,height:canvas.pictureHeight) {
            view.drawableSize = CGSize(width:canvas.pictureWidth,height:canvas.pictureHeight)
        }
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let command = queue.makeCommandBuffer() else { inFlight.signal(); return }
        let snapshot = store.snapshot()
        let frame = driver.frame(sample:snapshot.sample,settings:settings.motion,
                                 token:MotionDriver.Token(reset:settings.responseReset,mode:.motion))
        lastFrame = frame
        // The effect is zero at rest, and a transparent window costs nothing to
        // look at: skip the whole pipeline and just clear, so an idle overlay
        // leaves the GPU alone.
        let wantsEffect = frame.blur > 0.0005 || settings.motion.debugMask
        // Never draw while the capture can still see this window: the overlay
        // would become its own source and the transform would compound every
        // frame. The window stays empty until the filter excludes it.
        let safeToDraw = capture.isExcludingOwnWindows
        var frameSource: CVPixelBuffer?
        var hasPicture = false
        if let (buffer, _) = capture.takeLatest() {
            hasPicture = encodeFill(buffer:buffer,command:command)
            frameSource = buffer
        }
        let drawing = wantsEffect && hasPicture && safeToDraw
        if drawing { encodePyramid(command:command) }
        // The pass is encoded either way: with no effect the drawable still has
        // to be cleared, otherwise it is presented with undefined contents.
        guard encodeComposite(descriptor:pass,drawableSize:view.drawableSize,frame:frame,draw:drawing,command:command) else {
            inFlight.signal(); return
        }
        command.present(drawable)
        let held = frameSource
        command.addCompletedHandler { [weak self, inFlight] buffer in
            _ = held // keep the captured buffer alive until the GPU is done
            inFlight.signal()
            let gpuMs = max(0,buffer.gpuEndTime-buffer.gpuStartTime)*1000
            DispatchQueue.main.async {
                PerformanceMetrics.shared.live(gpuMilliseconds:drawing ? gpuMs : 0)
                if let error = buffer.error, self?.reportedError == false {
                    self?.reportedError = true
                    NSLog("Ajar live overlay command failed: %@",error.localizedDescription)
                }
            }
        }
        command.commit()
        PerformanceMetrics.shared.liveFrame(sampleTimestamp:snapshot.sample?.timestamp)
    }

    /// Runs the shared composite shader into an arbitrary render pass. Used by
    /// the overlay's drawable and by the pixel tests.
    @discardableResult
    func encodeComposite(descriptor: MTLRenderPassDescriptor, drawableSize: CGSize, frame: MotionFrame,
                         draw: Bool, command: MTLCommandBuffer) -> Bool {
        guard let encoder = command.makeRenderCommandEncoder(descriptor:descriptor) else { return false }
        if draw && levels.count == LiveCanvas.levelCount {
            var uniforms = MetalUniforms(liveFrame:frame,settings:settings.motion,
                                         frameAspect:Double(drawableSize.width/max(1,drawableSize.height)),
                                         pictureAspect:canvas.pictureAspect,canvas:canvas)
            encoder.setRenderPipelineState(compositePipeline)
            encoder.setFragmentBytes(&uniforms,length:MemoryLayout<MetalUniforms>.stride,index:0)
            encoder.setFragmentTextures(levels.map(Optional.some),range:0..<LiveCanvas.levelCount)
            encoder.setFragmentTextures(levels.map(Optional.some),range:LiveCanvas.levelCount..<2*LiveCanvas.levelCount)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        }
        encoder.endEncoding()
        return true
    }

    /// Copies the captured frame into the padded canvas. Returns false when the
    /// frame cannot be used, which leaves the overlay transparent for that frame.
    @discardableResult
    func encodeFill(buffer: CVPixelBuffer, command: MTLCommandBuffer) -> Bool {
        guard let cache = textureCache else { return false }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { return false }
        var source: CVMetalTexture?
        let attributes: [CFString: Any] = [kCVMetalTextureUsage: MTLTextureUsage.shaderRead.rawValue]
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault,cache,buffer,
                                                        attributes as CFDictionary,.bgra8Unorm,
                                                        width,height,0,&source) == kCVReturnSuccess,
              let image = source, let sourceTexture = CVMetalTextureGetTexture(image)
        else { return false }
        CVMetalTextureCacheFlush(cache,0)
        return encodeFill(sourceTexture:sourceTexture,command:command)
    }

    /// Same fill, from any texture, so the canvas layout can be tested without a
    /// live capture.
    @discardableResult
    func encodeFill(sourceTexture: MTLTexture, command: MTLCommandBuffer) -> Bool {
        let width = sourceTexture.width
        let height = sourceTexture.height
        guard width > 0, height > 0 else { return false }
        if canvas.pictureWidth != width || canvas.pictureHeight != height { rebuild(width:width,height:height) }
        guard let canvasTexture = levels.first, !reduced.isEmpty,
              let descriptor = passDescriptor(for:canvasTexture,load:.dontCare),
              let encoder = command.makeRenderCommandEncoder(descriptor:descriptor) else { return false }
        var picture = canvas.pictureRect
        encoder.setRenderPipelineState(fillPipeline)
        encoder.setFragmentBytes(&picture,length:MemoryLayout<SIMD4<Float>>.stride,index:0)
        encoder.setFragmentTexture(sourceTexture,index:0)
        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
        encoder.endEncoding()
        return true
    }

    /// One 2× reduce plus a small blur per level, which together produce the same
    /// effective sigma ladder as the cached levels of the static preview.
    func encodePyramid(command: MTLCommandBuffer) {
        guard reduced.count == blurs.count, levels.count == blurs.count + 1 else { return }
        for (index, blur) in blurs.enumerated() {
            let source = levels[index]
            let destination = reduced[index]
            guard let descriptor = passDescriptor(for:destination,load:.dontCare),
                  let encoder = command.makeRenderCommandEncoder(descriptor:descriptor) else { return }
            var texel = SIMD2<Float>(0.5/Float(max(1,source.width)),0.5/Float(max(1,source.height)))
            encoder.setRenderPipelineState(reducePipeline)
            encoder.setFragmentBytes(&texel,length:MemoryLayout<SIMD2<Float>>.stride,index:0)
            encoder.setFragmentTexture(source,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3)
            encoder.endEncoding()
            blur.encode(commandBuffer:command,sourceTexture:destination,destinationTexture:levels[index+1])
        }
    }

    private func passDescriptor(for texture: MTLTexture, load: MTLLoadAction) -> MTLRenderPassDescriptor? {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = load
        descriptor.colorAttachments[0].storeAction = .store
        return descriptor
    }

    private func rebuild(width: Int, height: Int) {
        canvas = LiveCanvas(pictureWidth:width,pictureHeight:height)
        levels = []; reduced = []; blurs = []
        let sizes = canvas.levelSizes
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:2,height:2,mipmapped:false)
        descriptor.usage = [.shaderRead,.shaderWrite,.renderTarget]
        descriptor.storageMode = .private
        for (index, size) in sizes.enumerated() {
            descriptor.width = size.width
            descriptor.height = size.height
            guard let texture = device.makeTexture(descriptor:descriptor) else { return }
            levels.append(texture)
            if index < sizes.count-1 {
                descriptor.width = max(2,sizes[index+1].width)
                descriptor.height = max(2,sizes[index+1].height)
                guard let scratch = device.makeTexture(descriptor:descriptor) else { return }
                reduced.append(scratch)
            }
            descriptor.width = size.width
            descriptor.height = size.height
        }
        let sigmas = LiveCanvas.levelSigmas(pictureHeight:height)
        for sigma in sigmas {
            let blur = MPSImageGaussianBlur(device:device,sigma:Float(max(0.1,sigma)))
            blur.edgeMode = .clamp
            blurs.append(blur)
        }
        NSLog("Ajar live overlay canvas %d×%d from %d×%d, sigmas %@",canvas.canvasWidth,canvas.canvasHeight,
              width,height,sigmas.map { String(format:"%.2f",$0) }.joined(separator:", "))
    }
}

/// The overlay window is click-through and never becomes key, so Escape is
/// handled by a monitor instead of by the window's responder chain.
struct LiveTransitionView: NSViewRepresentable {
    let store: HingeStore
    let capture: LiveScreenCapture
    let settings: RenderSettings
    final class Coordinator { var renderer: LiveTransitionRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        guard let device = MTLCreateSystemDefaultDevice() else { return message("Metal unavailable") }
        let view = MTKView(frame:.zero,device:device)
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0,0,0,0)
        view.autoResizeDrawable = false
        view.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.wantsLayer = true
        view.layer?.isOpaque = false
        (view.layer as? CAMetalLayer)?.isOpaque = false
        do {
            let renderer = try LiveTransitionRenderer(device:device,store:store,capture:capture,settings:settings)
            context.coordinator.renderer = renderer
            view.delegate = renderer
            view.setAccessibilityLabel("Hinge-driven live screen overlay")
            return view
        } catch {
            return message(error.localizedDescription)
        }
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.renderer?.settings = settings }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        (view as? MTKView)?.isPaused = true
        (view as? MTKView)?.delegate = nil
        coordinator.renderer = nil
    }
    private func message(_ text: String) -> NSView {
        let field = NSTextField(wrappingLabelWithString:text)
        field.textColor = .systemOrange
        return field
    }
}
