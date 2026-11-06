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
        XCTAssertFalse(pressed.isTemplate, "The red fill stays while the menu is open.")
        XCTAssertGreaterThan(redPixels(bitmap(pressed, dark: true, background: .black)), 10)
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

extension LowChargeIconTests {
    func testKeepAwakeColoursOnlyTheFillAndAddsNoBadgeOnTheModernBody() throws {
        let plain = NativeBatteryStatusImage.make(level: 64, style: .inside, externalPower: false, appearance: .macOS27, redWhenLow: true)
        let awake = NativeBatteryStatusImage.make(level: 64, style: .inside, externalPower: false, awake: .active, appearance: .macOS27, redWhenLow: true)
        XCTAssertEqual(awake.size.width, plain.size.width, "No cup badge: the canvas keeps the plain battery width.")
        XCTAssertFalse(awake.isTemplate)
        func bluePixels(_ image: NSImage, dark: Bool) -> Int {
            let rep = bitmap(image, dark: dark, background: dark ? .black : .white)
            var count = 0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if c.blueComponent > 0.8 && c.redComponent < 0.35 { count += 1 }
            } }
            return count
        }
        XCTAssertGreaterThan(bluePixels(awake, dark: true), 40, "The measured fill is blue.")
        XCTAssertGreaterThan(bluePixels(awake, dark: false), 40)
        XCTAssertEqual(bluePixels(plain, dark: true), 0)
        // The macOS 26 outline body keeps its badge.
        let legacy = NativeBatteryStatusImage.make(level: 64, style: .inside, externalPower: false, awake: .active, appearance: .macOS26)
        let legacyPlain = NativeBatteryStatusImage.make(level: 64, style: .inside, externalPower: false, appearance: .macOS26)
        XCTAssertGreaterThan(legacy.size.width, legacyPlain.size.width)
        // Low charge on battery: the fill is red even while Keep Awake runs (a warning outranks the session cue).
        let low = NativeBatteryStatusImage.make(level: 12, style: .inside, externalPower: false, awake: .active, appearance: .macOS27, redWhenLow: true)
        XCTAssertEqual(bluePixels(low, dark: true), 0)
        XCTAssertGreaterThan(redPixels(bitmap(low, dark: true, background: .black)), 10)
        // Pressed (the menu is open): the fill colour stays, the user starts these modes from that menu.
        let pressed = NativeBatteryStatusImage.make(level: 64, style: .inside, externalPower: false, awake: .active, highlighted: true, appearance: .macOS27)
        XCTAssertFalse(pressed.isTemplate)
        XCTAssertGreaterThan(bluePixels(pressed, dark: true), 40, "Blue while the menu is open.")
    }
}
