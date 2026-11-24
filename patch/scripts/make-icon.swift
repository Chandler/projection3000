import AppKit
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory:true)
try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels = size*scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        let transform = NSAffineTransform(); transform.scale(by:CGFloat(pixels)/1024); transform.concat()
        NSColor(calibratedRed:0.12,green:0.15,blue:0.17,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:32,y:32,width:960,height:960),xRadius:210,yRadius:210).fill()
        let purple = NSColor(calibratedRed:0.69,green:0.56,blue:0.90,alpha:1)
        let mint = NSColor(calibratedRed:0.57,green:0.83,blue:0.66,alpha:1)
        let blue = NSColor(calibratedRed:0.39,green:0.68,blue:0.83,alpha:1)
        for (from,to,color) in [(NSPoint(x:326,y:700),NSPoint(x:688,y:512),purple),(NSPoint(x:326,y:324),NSPoint(x:688,y:512),blue)] {
            let p = NSBezierPath(); p.move(to:from); p.curve(to:to,controlPoint1:NSPoint(x:520,y:from.y),controlPoint2:NSPoint(x:490,y:to.y)); p.lineWidth = 28; color.setStroke(); p.stroke()
        }
        for (x,y,color) in [(CGFloat(220),CGFloat(632),purple),(220,256,blue),(648,444,mint)] {
            color.setFill(); NSBezierPath(roundedRect:NSRect(x:x,y:y,width:148,height:136),xRadius:23,yRadius:23).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try bitmap.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
