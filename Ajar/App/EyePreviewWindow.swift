import AppKit
import SwiftUI

/// "Detect where I'm sitting" takes about a second and then moves a dot in a
/// side view. Without this window that is a black box: something happened, the
/// camera light blinked, and a number changed. The window shows the frames the
/// detector is actually looking at, with the two pupil points it read marked on
/// them, and stays up for a few seconds after the answer arrives so the user can
/// see what it was looking at.
final class EyePreviewModel: ObservableObject {
    enum Mood { case working, ok, failed }

    @Published var frame: EyeFrame?
    @Published var status = "Looking…"
    @Published var detail = "The camera light is on for about a second. Nothing is recorded and nothing is sent."
    @Published var mood = Mood.working

    func reset() {
        frame = nil
        status = "Looking…"
        detail = "The camera light is on for about a second. Nothing is recorded and nothing is sent."
        mood = .working
    }
}

/// Where a point in the camera image lands in a view that draws that image with
/// aspect-fit. Apart from the view so it can be checked without a window.
enum EyePreviewGeometry {
    static func fitted(imageSize: CGSize, in bounds: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width/imageSize.width, bounds.height/imageSize.height)
        let size = CGSize(width:imageSize.width*scale, height:imageSize.height*scale)
        return CGRect(x:(bounds.width-size.width)/2, y:(bounds.height-size.height)/2,
                      width:size.width, height:size.height)
    }

    /// Both the image and the view put y down, so this is a scale and an offset
    /// and nothing else.
    static func viewPoint(_ point: CGPoint, imageSize: CGSize, in bounds: CGSize) -> CGPoint {
        let rect = fitted(imageSize:imageSize, in:bounds)
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return CGPoint(x:rect.minX + point.x/imageSize.width*rect.width,
                       y:rect.minY + point.y/imageSize.height*rect.height)
    }
}

struct EyePreviewView: View {
    @ObservedObject var model: EyePreviewModel

    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            ZStack {
                Color.black
                if let frame = model.frame {
                    Image(decorative:frame.image,scale:1)
                        .resizable()
                        .aspectRatio(contentMode:.fit)
                    GeometryReader { proxy in
                        ForEach(Array(frame.pupils.enumerated()),id:\.offset) { _, point in
                            marker(usable:frame.usable)
                                .position(EyePreviewGeometry.viewPoint(point,
                                                                       imageSize:frame.size,
                                                                       in:proxy.size))
                        }
                    }
                } else {
                    Text("Waiting for the camera…")
                        .font(.callout).foregroundStyle(.white.opacity(0.7))
                }
            }
            // 16:9, which is the format the detector asks the camera for, so the
            // picture fills the box instead of sitting in black bars.
            .frame(height:207)
            .clipShape(RoundedRectangle(cornerRadius:8))

            Text(model.status).font(.headline)
            Text(model.detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal:false,vertical:true)
        }
        .padding(16)
        .frame(width:400)
    }

    /// A ring around the point rather than a filled dot: the pupil is still
    /// visible inside it, which is the whole point of the picture.
    private func marker(usable: Bool) -> some View {
        let color: Color = usable ? .green : .orange
        return ZStack {
            Circle().stroke(color,lineWidth:2).frame(width:26,height:26)
            Circle().fill(color).frame(width:4,height:4)
        }
    }
}

/// One window for the process: the button lives in Settings and in the
/// walkthrough, and only one detection can run at a time (`EyeDetector` refuses
/// a second), so a second window would only ever be a duplicate.
final class EyePreviewWindowController: NSObject, NSWindowDelegate {
    static let shared = EyePreviewWindowController()
    private var window: NSWindow?
    private var closeWork: DispatchWorkItem?
    private let model = EyePreviewModel()

    func begin() {
        closeWork?.cancel()
        closeWork = nil
        model.reset()
        if window == nil { build() }
        // Ordered front, not made key: the button that started this stays where
        // the user's attention is, and the preview is a floating neighbour.
        window?.orderFront(nil)
    }

    func show(_ frame: EyeFrame) { model.frame = frame }

    /// Keeps the last frame and the answer on screen for a few seconds, then
    /// closes: the picture is the receipt for the measurement.
    func finish(_ outcome: Outcome) {
        switch outcome {
        case .found(let note):
            model.status = "Eyes found"
            model.detail = note + ". Nothing was recorded."
            model.mood = .ok
            // Straight down. The picture has been on screen for the whole
            // second the detector spent sampling, so once the answer is in
            // there is nothing left to look at, and a delay only reads as a
            // dialog waiting to be dismissed.
            closeNow()
        case .failed(let message):
            model.status = "No usable eyes"
            model.detail = message
            model.mood = .failed
            // A refusal has a sentence to read, and the same sentence is in
            // Settings, so it gets longer than the success case and no more.
            close(after:3)
        }
    }

    enum Outcome { case found(String), failed(String) }

    private func closeNow() {
        closeWork?.cancel()
        closeWork = nil
        window?.orderOut(nil)
    }

    private func close(after seconds: Double) {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.window?.orderOut(nil) }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline:.now()+seconds,execute:work)
    }

    private func build() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:400,height:360),
                              styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title = "Looking for your eyes"
        window.level = .floating          // above Settings, and above the effect
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView:EyePreviewView(model:model))
        window.setContentSize(window.contentView?.fittingSize ?? NSSize(width:400,height:430))
        window.center()
        // Where the button is: the walkthrough or Settings can be on any screen,
        // and a preview on the other one is not a preview of anything.
        (NSApp.keyWindow?.screen ?? NSScreen.main).map { screen in
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x:visible.midX-window.frame.width/2,
                                          y:visible.midY-window.frame.height/2))
        }
        self.window = window
    }
}
