// Original AppKit rendering of Assets/AppIcon.svg geometry; no external artwork/fonts.
import AppKit
let destination = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(srgbRed: 0.98, green: 0.984, blue: 0.961, alpha: 1), ending: NSColor(srgbRed: 0.882, green: 0.910, blue: 0.859, alpha: 1))!.draw(in: tile, angle: -90)
let loop = NSBezierPath(); loop.lineWidth = 88; loop.lineCapStyle = .round; loop.lineJoinStyle = .round
loop.move(to: NSPoint(x: 380, y: 734)); loop.line(to: NSPoint(x: 342, y: 734))
loop.curve(to: NSPoint(x: 244, y: 636), controlPoint1: NSPoint(x: 288, y: 734), controlPoint2: NSPoint(x: 244, y: 690))
loop.line(to: NSPoint(x: 244, y: 350)); loop.curve(to: NSPoint(x: 342, y: 252), controlPoint1: NSPoint(x: 244, y: 296), controlPoint2: NSPoint(x: 288, y: 252))
loop.line(to: NSPoint(x: 682, y: 252)); loop.curve(to: NSPoint(x: 780, y: 350), controlPoint1: NSPoint(x: 736, y: 252), controlPoint2: NSPoint(x: 780, y: 296))
loop.line(to: NSPoint(x: 780, y: 636)); loop.curve(to: NSPoint(x: 682, y: 734), controlPoint1: NSPoint(x: 780, y: 690), controlPoint2: NSPoint(x: 736, y: 734)); loop.line(to: NSPoint(x: 644, y: 734))
NSColor(srgbRed: 0.149, green: 0.212, blue: 0.184, alpha: 1).setStroke(); loop.stroke()
let stem = NSBezierPath(); stem.lineWidth = 88; stem.lineCapStyle = .round
stem.move(to: NSPoint(x: 512, y: 754)); stem.line(to: NSPoint(x: 512, y: 484))
NSColor(srgbRed: 0.569, green: 0.784, blue: 0.435, alpha: 1).setStroke(); stem.stroke()
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
