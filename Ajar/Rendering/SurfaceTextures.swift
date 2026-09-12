import AppKit

// Static test surfaces rasterize once. No SwiftUI snapshots or blur work in draw().
//
// The picture is the screen content. It is padded with black above, left and
// right — but not below, because the bottom edge is the hinge — so the panel has
// somewhere to swing, and so the blur has black to soften into at its border.
// At rest the picture spans the whole frame and the padding sits off-screen.
enum SurfaceTextures {
    static let imageWidth = 1600
    static let imageHeight = 1000
    static let padSideFraction = 0.20   // of the picture height
    static let padTopFraction = 0.25

    static var padSidePixels: Int { Int((Double(imageHeight)*padSideFraction).rounded()) }
    static var padTopPixels: Int { Int((Double(imageHeight)*padTopFraction).rounded()) }
    static var width: Int { imageWidth+2*padSidePixels }
    static var height: Int { imageHeight+padTopPixels }

    /// The picture's own shape, which is what the frame shows at rest.
    static var aspect: Double { Double(imageWidth)/Double(imageHeight) }
    /// Padding in picture-height units, which is what the shader works in.
    static var padSide: Double { Double(padSidePixels)/Double(imageHeight) }
    static var padTop: Double { Double(padTopPixels)/Double(imageHeight) }

    static func pixels(incoming: Bool) -> [UInt8] {
        var pixels = [UInt8](repeating:0,count:width*height*4)
        pixels.withUnsafeMutableBytes { raw in
            let context = CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
            defer { NSGraphicsContext.restoreGraphicsState() }
            // Everything outside the picture stays black; the picture is drawn
            // inside the padding.
            NSColor.black.setFill(); NSRect(x:0,y:0,width:width,height:height).fill()
            context.translateBy(x:CGFloat(padSidePixels),y:0)

            let base = incoming ? NSColor(calibratedRed:0.30,green:0.13,blue:0.06,alpha:1) : NSColor(calibratedRed:0.035,green:0.15,blue:0.20,alpha:1)
            base.setFill(); NSRect(x:0,y:0,width:imageWidth,height:imageHeight).fill()
            let glow = incoming ? NSColor.systemOrange : NSColor.systemTeal
            glow.withAlphaComponent(0.22).setFill()
            NSBezierPath(ovalIn:NSRect(x:910,y:330,width:900,height:900)).fill()
            for i in 0..<9 {
                NSColor.white.withAlphaComponent(0.055).setStroke()
                let path = NSBezierPath(ovalIn:NSRect(x:875-Double(i)*26,y:410-Double(i)*26,width:400+Double(i)*52,height:400+Double(i)*52))
                path.lineWidth = 1; path.stroke()
            }
            text(incoming ? "B   /   GOLDEN HOUR" : "A   /   DEEP WATER",x:110,y:865,size:20,weight:.semibold,color:.white.withAlphaComponent(0.7))
            text(incoming ? "Find a new" : "Make room",x:104,y:700,size:100,weight:.bold)
            text(incoming ? "perspective." : "for focus.",x:104,y:585,size:100,weight:.bold)
            text(incoming ? "Ideas emerge as the light changes." : "A quiet surface. A clear beginning.",x:110,y:515,size:30,weight:.regular,color:.white.withAlphaComponent(0.75))
            for i in 0..<3 {
                let x = 110+Double(i)*455
                NSColor.white.withAlphaComponent(0.09).setFill()
                NSBezierPath(roundedRect:NSRect(x:x,y:150,width:420,height:295),xRadius:28,yRadius:28).fill()
                glow.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect:NSRect(x:x+30,y:345,width:58,height:58),xRadius:16,yRadius:16).fill()
                text(["01","02","03"][i],x:x+40,y:363,size:19,weight:.bold)
                let titles = incoming ? ["Explore","Connect","Create"] : ["Collect","Consider","Clarify"]
                text(titles[i],x:x+30,y:272,size:33,weight:.semibold)
                text(incoming ? "Follow the possibility" : "Keep what matters",x:x+30,y:222,size:22,weight:.regular,color:.white.withAlphaComponent(0.65))
            }
            text("HINGE STUDIES     /     001",x:110,y:80,size:18,weight:.medium,color:.white.withAlphaComponent(0.45))
            text(incoming ? "WARM / OPEN" : "COOL / CLOSED",x:1230,y:80,size:18,weight:.medium,color:.white.withAlphaComponent(0.45))
        }
        return pixels
    }
    private static func text(_ text: String,x:Double,y:Double,size:Double,weight:NSFont.Weight,color:NSColor = .white) {
        (text as NSString).draw(at:NSPoint(x:x,y:y),withAttributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color])
    }
}
