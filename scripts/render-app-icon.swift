// Original AppKit rendering of the TilveroEnergyMark geometry; no external art/fonts.
import AppKit
let destination = CommandLine.arguments[1]
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(srgbRed: 0.984, green: 0.988, blue: 0.980, alpha: 1), ending: NSColor(srgbRed: 0.874, green: 0.906, blue: 0.878, alpha: 1))!.draw(in: tile, angle: -90)
NSColor(srgbRed: 0.2, green: 0.32, blue: 0.24, alpha: 0.09).setStroke()
tile.lineWidth = 2; tile.stroke()
func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: 190 + x * 644, y: 782 - y * 540) }
let mark = NSBezierPath(); mark.lineWidth = 78; mark.lineCapStyle = .round; mark.lineJoinStyle = .round
mark.move(to: point(0.04, 0.66))
mark.curve(to: point(0.29, 0.25), controlPoint1: point(0.13, 0.66), controlPoint2: point(0.16, 0.13))
mark.curve(to: point(0.56, 0.74), controlPoint1: point(0.40, 0.25), controlPoint2: point(0.42, 0.74))
mark.curve(to: point(0.82, 0.26), controlPoint1: point(0.68, 0.74), controlPoint2: point(0.69, 0.26))
mark.curve(to: point(0.96, 0.40), controlPoint1: point(0.87, 0.26), controlPoint2: point(0.90, 0.40))
let shadow = NSShadow(); shadow.shadowColor = NSColor(srgbRed: 0.08, green: 0.26, blue: 0.14, alpha: 0.12)
shadow.shadowBlurRadius = 12; shadow.shadowOffset = NSSize(width: 0, height: -7); shadow.set()
NSColor(srgbRed: 0.13, green: 0.65, blue: 0.32, alpha: 1).setStroke(); mark.stroke()
NSGraphicsContext.restoreGraphicsState()
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination))
