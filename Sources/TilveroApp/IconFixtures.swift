import AppKit
import Foundation

/// Offline rendering of the real status-image implementation; never reads or writes hardware.
@MainActor
enum IconFixtures {
    static func render(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let levels: [Int?] = [0,1,9,10,50,88,99,100,nil]
        for scale in [1,2] {
            for dark in [false,true] {
                let size = NSSize(width: 520, height: 365)
                let image = NSImage(size: size)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size; image.addRepresentation(rep)
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                (dark ? NSColor.black : NSColor.white).setFill(); NSRect(origin: .zero, size: size).fill()
                let foreground = dark ? NSColor.white : NSColor.black
                let attrs: [NSAttributedString.Key: Any] = [.font:NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular), .foregroundColor:foreground]
                for (row,level) in levels.enumerated() {
                    let y = CGFloat(315 - row * 32)
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
                ("Beside / Inside / Icon only · battery + adapter" as NSString).draw(at:NSPoint(x:12,y:343),withAttributes:attrs)
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using:.png,properties:[:])!.write(to:directory.appendingPathComponent("icons-\(dark ? "dark" : "light")-\(scale)x.png"))
            }
        }
        try renderRefinementSheet(to: directory)
    }

    /// Real AppKit renderings of both typography presets; drawing only, with no
    /// telemetry, preferences, menu items, or hardware interaction.
    private static func renderRefinementSheet(to directory: URL) throws {
        let levels: [Int?] = [0, 1, 9, 10, 50, 88, 99, 100, nil]
        let variants: [(MenuBarDisplayStyle, MenuBarTextSize, String)] = [
            (.beside, .system, "Normal · System"),
            (.inside, .system, "Inside · System"),
            (.inside, .larger, "Inside · Larger")
        ]
        for scale in [1, 2] {
            for dark in [false, true] {
                let size = NSSize(width: 680, height: 430)
                let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale,
                    pixelsHigh: Int(size.height) * scale, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                rep.size = size
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                (dark ? NSColor(calibratedWhite: 0.08, alpha: 1) : NSColor(calibratedWhite: 0.95, alpha: 1)).setFill()
                NSRect(origin: .zero, size: size).fill()
                let foreground = dark ? NSColor.white : NSColor.black
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: foreground]
                for (column, variant) in variants.enumerated() {
                    let x = CGFloat(90 + column * 192)
                    (variant.2 as NSString).draw(at: NSPoint(x: x, y: 404), withAttributes: attrs)
                    ("Battery          Adapter" as NSString).draw(at: NSPoint(x: x, y: 384), withAttributes: attrs)
                }
                for (row, level) in levels.enumerated() {
                    let y = CGFloat(350 - row * 34)
                    ((level.map { "\($0)%" } ?? "unknown") as NSString).draw(at: NSPoint(x: 12, y: y), withAttributes: attrs)
                    for (column, variant) in variants.enumerated() {
                        for ac in [false, true] {
                            let icon = NativeBatteryStatusImage.make(level: level, style: variant.0, externalPower: ac, textSize: variant.1)
                            draw(icon, at: NSPoint(x: CGFloat(90 + column * 192 + (ac ? 90 : 0)), y: y - 2), color: foreground, scale: scale)
                        }
                    }
                }
                ("Icon size 85% / 100% / 115%   ·   88%, adapter attached" as NSString).draw(at: NSPoint(x: 12, y: 48), withAttributes: attrs)
                for (index, iconScale) in [CGFloat(0.85), 1, 1.15].enumerated() {
                    let normal = NativeBatteryStatusImage.make(level: 88, style: .beside, externalPower: true, scale: iconScale)
                    let inside = NativeBatteryStatusImage.make(level: 88, style: .inside, externalPower: true, scale: iconScale)
                    draw(normal, at: NSPoint(x: CGFloat(340 + index * 95), y: 42), color: foreground, scale: scale)
                    draw(inside, at: NSPoint(x: CGFloat(340 + index * 95), y: 12), color: foreground, scale: scale)
                }
                NSGraphicsContext.restoreGraphicsState()
                try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("contact-\(dark ? "dark" : "light")-\(scale)x.png"))
            }
        }
    }

    private static func draw(_ icon: NSImage, at point: NSPoint, color: NSColor, scale: Int) {
        icon.isTemplate = false
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((icon.size.width * CGFloat(scale)).rounded(.up)),
            pixelsHigh: Int((icon.size.height * CGFloat(scale)).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = icon.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        NSRect(origin: .zero, size: icon.size).fill(using: .sourceIn)
        NSGraphicsContext.restoreGraphicsState()
        let tinted = NSImage(size: icon.size)
        tinted.addRepresentation(rep)
        tinted.draw(at: point, from: .zero, operation: .sourceOver, fraction: 1)
    }
}
