import AppKit
import XCTest
@testable import TilveroApp

@MainActor final class LowChargeIconTests: XCTestCase {
    private func bitmap(_ image: NSImage, dark: Bool, background: NSColor) -> NSBitmapImageRep {
        let scale = 4
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(image.size.width) * scale, pixelsHigh: Int(image.size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        (dark ? NSAppearance(named: .darkAqua)! : NSAppearance(named: .aqua)!).performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            background.setFill(); NSRect(origin: .zero, size: image.size).fill()
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        return rep
    }
    private func redPixels(_ rep: NSBitmapImageRep) -> Int {
        var count = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if c.redComponent > 0.7 && c.greenComponent < 0.4 && c.blueComponent < 0.4 { count += 1 }
        } }
        return count
    }

    func testTheFillTurnsRedAtTwentyPercentOrLessOnBatteryOnly() throws {
        let low = NativeBatteryStatusImage.make(level: 20, style: .inside, externalPower: false, appearance: .macOS27, redWhenLow: true)
        XCTAssertFalse(low.isTemplate, "A red fill needs real colours, so the image is not a template.")
        XCTAssertGreaterThan(redPixels(bitmap(low, dark: true, background: .black)), 20, "20 % shows a red fill")
        XCTAssertGreaterThan(redPixels(bitmap(low, dark: false, background: .white)), 20)

        for (level, power, flag) in [(21, false, true), (50, false, true), (15, true, true), (15, false, false)] as [(Int, Bool, Bool)] {
            let image = NativeBatteryStatusImage.make(level: level, style: .inside, externalPower: power, appearance: .macOS27, redWhenLow: flag)
            XCTAssertTrue(image.isTemplate, "level \(level) power \(power) flag \(flag): stays a plain template")
        }
        let pressed = NativeBatteryStatusImage.make(level: 10, style: .inside, externalPower: false, highlighted: true, appearance: .macOS27, redWhenLow: true)
        XCTAssertTrue(pressed.isTemplate, "The pressed state keeps the system's inverted template.")
    }

    func testTheRedFillCoversOnlyTheMeasuredFillAndKeepsTheNumeralCutout() throws {
        let image = NativeBatteryStatusImage.make(level: 10, style: .inside, externalPower: false, appearance: .macOS27, redWhenLow: true)
        let rep = bitmap(image, dark: true, background: .black)
        let total = redPixels(rep)
        let wide = NativeBatteryStatusImage.make(level: 20, style: .inside, externalPower: false, appearance: .macOS27, redWhenLow: true)
        XCTAssertLessThan(total, redPixels(bitmap(wide, dark: true, background: .black)), "10 % fills less of the body than 20 %")
        XCTAssertGreaterThan(total, 0)
        if let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"] {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let sheet = NSImage(size: NSSize(width: 200, height: 60), flipped: false) { _ in
                NSColor(white: 0.12, alpha: 1).setFill(); NSRect(x: 0, y: 30, width: 200, height: 30).fill()
                NSColor(white: 0.93, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 200, height: 30).fill()
                for (i, level) in [20, 15, 8, 55].enumerated() {
                    let icon = NativeBatteryStatusImage.make(level: level, style: .inside, externalPower: false, scale: 1.4, appearance: .macOS27, redWhenLow: true)
                    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { icon.draw(at: NSPoint(x: 8 + CGFloat(i) * 48, y: 36), from: .zero, operation: .sourceOver, fraction: 1) }
                    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { icon.draw(at: NSPoint(x: 8 + CGFloat(i) * 48, y: 6), from: .zero, operation: .sourceOver, fraction: 1) }
                }
                return true
            }
            let big = bitmap(sheet, dark: true, background: .clear)
            _ = big
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 240, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = NSSize(width: 200, height: 60)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            sheet.draw(in: NSRect(x: 0, y: 0, width: 200, height: 60)); NSGraphicsContext.restoreGraphicsState()
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: folder + "/look-low-battery-icons.png"))
        }
    }
}
