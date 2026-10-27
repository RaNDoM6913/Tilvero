import AppKit
import Foundation

/// Offline rendering of the real status-image implementation; never reads or writes hardware.
@MainActor
enum IconFixtures {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let levels: [Int?] = [0,1,9,10,99,100,nil]
        for scale in [1,2] {
            for dark in [false,true] {
                let size = NSSize(width: 520, height: 300)
                let image = NSImage(size: size)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size; image.addRepresentation(rep)
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                (dark ? NSColor.black : NSColor.white).setFill(); NSRect(origin: .zero, size: size).fill()
                let foreground = dark ? NSColor.white : NSColor.black
                let attrs: [NSAttributedString.Key: Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor:foreground]
                for (row,level) in levels.enumerated() {
                    let y = CGFloat(250 - row * 32)
                    ((level.map { "\($0)%" } ?? "unknown") as NSString).draw(at: NSPoint(x: 12,y:y),withAttributes:attrs)
                    for (column,style) in MenuBarDisplayStyle.allCases.enumerated() {
                        for charging in [false,true] {
                            let icon = NativeBatteryStatusImage.make(level: level, style: style, externalPower: charging)
                            icon.isTemplate = false
                            let point=NSPoint(x:CGFloat(95 + column*135 + (charging ? 57 : 0)),y:y-3)
                            if dark {
                                let tinted=NSImage(size:icon.size);tinted.lockFocus()
                                icon.draw(at:.zero,from:.zero,operation:.sourceOver,fraction:1)
                                foreground.setFill();NSRect(origin:.zero,size:icon.size).fill(using:.sourceIn);tinted.unlockFocus()
                                tinted.draw(at:point,from:.zero,operation:.sourceOver,fraction:1)
                            } else { icon.draw(at:point,from:.zero,operation:.sourceOver,fraction:1) }
                        }
                    }
                }
                ("Beside / Inside / Icon only · battery + adapter" as NSString).draw(at:NSPoint(x:12,y:278),withAttributes:attrs)
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("icons-\(dark ? "dark" : "light")-\(scale)x.png"))
            }
        }
    }
}
