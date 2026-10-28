import AppKit
import XCTest
@testable import TilveroApp

@MainActor
final class NativeBatteryStatusImageTests: XCTestCase {
    func testNativeSymbolsExistOnTheSupportedOS() async throws {
        for name in ["battery.0percent", "battery.100percent", "battery.100percent.bolt"] {
            XCTAssertNotNil(NSImage(systemSymbolName: name, accessibilityDescription: nil), name)
        }
    }

    func testPercentageUsesSystemFontAndLocaleWithoutInventingAnUnknownZero() async throws {
        XCTAssertEqual(NativeStatusPresentation.font, NSFont.menuBarFont(ofSize: 0))
        XCTAssertEqual(NativeStatusPresentation.percentageTitle(level: 100, locale: Locale(identifier: "ru_RU")), "100\u{00A0}%")
        XCTAssertEqual(NativeStatusPresentation.percentageTitle(level: 100, locale: Locale(identifier: "en_US")), "100%")
        XCTAssertEqual(NativeStatusPresentation.percentageTitle(level: 0, locale: Locale(identifier: "ru_RU")), "0\u{00A0}%")
        for level in [nil, -1, 101] {
            XCTAssertEqual(NativeStatusPresentation.percentageTitle(level: level), "—")
        }
    }

    func testAllDigitWidthsAndUnknownRenderWithoutClipping() async throws {
        for style in MenuBarDisplayStyle.allCases {
            for externalPower in [false, true] {
                for level in [0, 1, 9, 10, 99, 100, nil] {
                    let image = NativeBatteryStatusImage.make(level: level, style: style, externalPower: externalPower)
                    XCTAssertTrue(image.isTemplate)
                    for scale in [1, 2] {
                        let rep = render(image, scale: scale)
                        let ink = occupied(rep)
                        XCTAssertFalse(ink.isEmpty, "\(style) / \(String(describing: level)) / AC \(externalPower)")
                        XCTAssertGreaterThan(ink.count, 20 * scale, "A missing native mask must not collapse to the fallback question mark.")
                        // The bolt and terminal both fit in the drawing canvas.
                        XCTAssertTrue(ink.allSatisfy { $0.y > 0 && $0.y < rep.pixelsHigh - 1 })
                        XCTAssertLessThan(edgeAlpha(rep), 0.35)
                    }
                }
            }
        }
    }

    func testUnknownAndInvalidRemainVisuallyDistinctFromMeasuredZeroInEveryStyle() async throws {
        for style in MenuBarDisplayStyle.allCases {
            for externalPower in [false, true] {
                let unknown = pixels(NativeBatteryStatusImage.make(level: nil, style: style, externalPower: externalPower))
                let zero = pixels(NativeBatteryStatusImage.make(level: 0, style: style, externalPower: externalPower))
                XCTAssertNotEqual(unknown, zero, "An unavailable value must not appear as an empty measured battery.")
                for invalid in [-1, 101] {
                    XCTAssertEqual(pixels(NativeBatteryStatusImage.make(level: invalid, style: style, externalPower: externalPower)), unknown)
                }
            }
        }
    }

    func testContinuousMeasuredFillAndACMarkerAreIndependent() async throws {
        // In the normal symbol modes only measured charge changes the fill.
        // An attached adapter changes the bolt even when charge is already 100%.
        for style in [MenuBarDisplayStyle.beside, .iconOnly] {
            let levels = [0, 1, 9, 10, 99, 100]
            let amounts = levels.map { level in
                alphaSum(render(NativeBatteryStatusImage.make(level: level, style: style, externalPower: false), scale: 8))
            }
            for index in 1..<amounts.count { XCTAssertGreaterThan(amounts[index], amounts[index - 1]) }
            let full = pixels(NativeBatteryStatusImage.make(level: 100, style: style, externalPower: false))
            let attached = pixels(NativeBatteryStatusImage.make(level: 100, style: style, externalPower: true))
            XCTAssertNotEqual(full, attached)
        }
    }

    func testDefaultSymbolDoesNotReserveAnUnpaintedRightGutter() async throws {
        let image = NativeBatteryStatusImage.make(level: 100, style: .beside, externalPower: true)
        let system = try XCTUnwrap(NSImage(systemSymbolName: "battery.100percent.bolt", accessibilityDescription: nil))
        XCTAssertLessThanOrEqual(image.size.width, system.withSymbolConfiguration(.init(pointSize: 18, weight: .regular, scale: .medium))!.size.width)
        let rep = render(image, scale: 8)
        let ink = occupied(rep)
        let last = try XCTUnwrap(ink.map(\.x).max())
        XCTAssertLessThan(CGFloat(rep.pixelsWide - 1 - last) / 8, 2, "Only native glyph padding may follow the terminal.")
        let top = try XCTUnwrap(ink.map(\.y).min())
        let bottom = try XCTUnwrap(ink.map(\.y).max())
        XCTAssertGreaterThan(bottom - top, 7 * 8, "The native battery must render, rather than the unavailable-symbol fallback.")
    }

    func testSystemPercentageMatchesTheSmallerReferenceAndPreservesLargerOption() async throws {
        func textImage(_ size: MenuBarTextSize) -> NSImage {
            NSImage(size: NSSize(width: 80, height: 30), flipped: false) { _ in
                (NativeStatusPresentation.percentageTitle(level: 100, locale: Locale(identifier: "ru_RU")) as NSString)
                    .draw(at: NSPoint(x: 4, y: 4), withAttributes: [.font: NativeStatusPresentation.font(for: size), .foregroundColor: NSColor.black])
                return true
            }
        }
        let small = occupied(render(textImage(.system), scale: 2), threshold: 0.5)
        let large = occupied(render(textImage(.larger), scale: 2), threshold: 0.5)
        func dimensions(_ points: [(x: Int, y: Int)]) -> NSSize {
            NSSize(width: points.map(\.x).max()! - points.map(\.x).min()! + 1,
                   height: points.map(\.y).max()! - points.map(\.y).min()! + 1)
        }
        let system = dimensions(small), larger = dimensions(large)
        // The owner's 2× reference measures approximately 63×16 strong pixels.
        XCTAssertTrue((61...65).contains(system.width))
        XCTAssertTrue((15...18).contains(system.height))
        XCTAssertGreaterThan(larger.width, system.width)
        XCTAssertGreaterThan(larger.height, system.height)
        XCTAssertEqual(NativeStatusPresentation.font(for: .larger), NativeStatusPresentation.font)
    }

    func testIconScalingChangesCanvasAndInkWithoutLosingUnknownState() async throws {
        for style in MenuBarDisplayStyle.allCases {
            for ac in [false, true] {
                var widths: [CGFloat] = [], inkWidths: [Int] = []
                for scale in [CGFloat(0.85), 1, 1.15] {
                    let image = NativeBatteryStatusImage.make(level: 100, style: style, externalPower: ac, scale: scale)
                    XCTAssertTrue(image.isTemplate)
                    widths.append(image.size.width)
                    let ink = occupied(render(image, scale: 8))
                    inkWidths.append(ink.map(\.x).max()! - ink.map(\.x).min()! + 1)
                    let unknown = NativeBatteryStatusImage.make(level: nil, style: style, externalPower: ac, scale: scale)
                    let zero = NativeBatteryStatusImage.make(level: 0, style: style, externalPower: ac, scale: scale)
                    XCTAssertNotEqual(pixels(unknown), pixels(zero))
                }
                for index in 1..<widths.count {
                    XCTAssertGreaterThan(widths[index], widths[index - 1])
                    XCTAssertGreaterThan(inkWidths[index], inkWidths[index - 1])
                }
            }
        }
    }

    func testCorruptScalePreferencesRetainTheVisibleDefaultIndicator() async throws {
        let original = NativeBatteryStatusImage.make(level: 100, style: .beside, externalPower: true)
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 0.84, 1.16, 100] {
            XCTAssertEqual(MenuBarSizing.validatedIconScale(value), 1)
            let image = NativeBatteryStatusImage.make(level: 100, style: .beside, externalPower: true, scale: CGFloat(value))
            XCTAssertEqual(image.size, original.size)
            XCTAssertEqual(pixels(image), pixels(original))
            XCTAssertFalse(occupied(render(image, scale: 2)).isEmpty)
        }
    }

    func testInsideTypographyChangesIndependentlyOfBatteryShellSize() async throws {
        for ac in [false, true] {
            let smaller = NativeBatteryStatusImage.make(level: 100, style: .inside, externalPower: ac, textSize: .system)
            let larger = NativeBatteryStatusImage.make(level: 100, style: .inside, externalPower: ac, textSize: .larger)
            XCTAssertEqual(smaller.size, larger.size)
            XCTAssertNotEqual(pixels(smaller), pixels(larger))
            let iconSmall = NativeBatteryStatusImage.make(level: 100, style: .iconOnly, externalPower: ac, textSize: .system)
            let iconLarge = NativeBatteryStatusImage.make(level: 100, style: .iconOnly, externalPower: ac, textSize: .larger)
            XCTAssertEqual(pixels(iconSmall), pixels(iconLarge))
        }
    }

    func testInsideDigitsHaveReadableHeightWithoutAnElongatedTube() async throws {
        for textSize in MenuBarTextSize.allCases {
            for ac in [false, true] {
                let image = NativeBatteryStatusImage.make(level: 0, style: .inside, externalPower: ac, textSize: textSize)
                XCTAssertLessThanOrEqual(image.size.width, 35, "The inside mode must remain a compact battery, including its AC cue.")
                let rep = render(image, scale: 8)
                // Measure the zero's central vertical stem, away from the shell
                // and optional right-side adapter cue. At zero this is text only.
                let unknown = render(NativeBatteryStatusImage.make(level: nil, style: .inside, externalPower: ac, textSize: textSize), scale: 8)
                let textInk = occupied(rep, threshold: 0.7).filter {
                    $0.x >= 6 * 8 && $0.x <= 20 * 8 && $0.y >= 4 * 8 && $0.y < 14 * 8 &&
                    abs(rep.colorAt(x: $0.x, y: $0.y)!.alphaComponent - unknown.colorAt(x: $0.x, y: $0.y)!.alphaComponent) > 0.5
                }
                let height = (textInk.map(\.y).max() ?? 0) - (textInk.map(\.y).min() ?? 0) + 1
                XCTAssertGreaterThanOrEqual(height, 7 * 8, "Inside numerals must be legible at actual menu-bar size.")
            }
        }
    }

    func testInsideFullBatteryKnocksOutDigitsInsteadOfPaintingOverFill() async throws {
        let full = render(NativeBatteryStatusImage.make(level: 100, style: .inside, externalPower: false), scale: 8)
        // A filled battery must contain contrasting numeral cutouts. A faint
        // fill with dark text makes charge unreadable and visually near-empty.
        let center = (5 * 8..<13 * 8).flatMap { y in
            (6 * 8..<22 * 8).map { x in full.colorAt(x: x, y: y)!.alphaComponent }
        }
        XCTAssertGreaterThan(center.filter { $0 > 0.9 }.count, center.count / 3)
        XCTAssertGreaterThan(center.filter { $0 < 0.1 }.count, center.count / 12)
    }

    func testNormalContourMatchesMeasuredNativeHeightAtTwoTimes() async throws {
        // Owner reference: body 46×24 physical pixels, terminal 3×8 at 2×.
        // Include secondary contour pixels using the same >90 channel cutoff
        // as white ink over black, not a threshold that discards the outline.
        let threshold = CGFloat(90) / 255
        for style in [MenuBarDisplayStyle.beside, .iconOnly] {
            for ac in [false, true] {
                for level in [0, 88, 100, nil] {
                    let rep = render(NativeBatteryStatusImage.make(level: level, style: style, externalPower: ac), scale: 2)
                    let body = occupied(rep, threshold: threshold).filter { $0.x < 48 }
                    XCTAssertEqual(body.map(\.x).max()! - body.map(\.x).min()! + 1, 46)
                    XCTAssertEqual(body.map(\.y).max()! - body.map(\.y).min()! + 1, 24, "The normal contour, including its stroke, must match the measured reference.")
                    let terminal = occupied(rep, threshold: threshold).filter { $0.x >= 48 }
                    XCTAssertEqual(terminal.map(\.x).max()! - terminal.map(\.x).min()! + 1, 3)
                    XCTAssertEqual(terminal.map(\.y).max()! - terminal.map(\.y).min()! + 1, 8)
                }
            }
        }
        let rep = render(NativeBatteryStatusImage.make(level: 0, style: .iconOnly, externalPower: false), scale: 2)
        let maximumAlpha = occupied(rep).map { rep.colorAt(x: $0.x, y: $0.y)!.alphaComponent }.max() ?? 0
        XCTAssertLessThan(maximumAlpha, 0.8)
        XCTAssertGreaterThan(maximumAlpha, 0.4)
    }

    func testInsideThreeDigitsLeaveAVisibleGapBeforeAdapterBolt() async throws {
        for textSize in MenuBarTextSize.allCases {
            let rep = render(NativeBatteryStatusImage.make(level: 0, style: .inside, externalPower: true, textSize: textSize), scale: 8)
            // The rightmost zero of 100 is wider than the zero fixture above.
            // At full charge the intervening strip must be opaque reservoir,
            // separating the clear numeral from the clear adapter bolt.
            let full = render(NativeBatteryStatusImage.make(level: 100, style: .inside, externalPower: true, textSize: textSize), scale: 8)
            for y in 6 * 8..<12 * 8 {
                XCTAssertEqual(rep.colorAt(x: 25 * 8, y: y)!.alphaComponent, 0.2, accuracy: 0.02)
                XCTAssertGreaterThan(full.colorAt(x: 25 * 8, y: y)!.alphaComponent, 0.95)
            }
        }
    }

    func testInsideMeasuredFillRemainsContinuousBelowDigits() async throws {
        var amounts: [CGFloat] = []
        for level in [0, 1, 9, 10, 50, 88, 99, 100] {
            let rep = render(NativeBatteryStatusImage.make(level: level, style: .inside, externalPower: false), scale: 8)
            // Bottom track excludes the text; include its centre-height left
            // and right edges so 1% and 99–100% remain measurable despite
            // rounded corners at the bottom of the track.
            let amount = (0..<rep.pixelsWide).reduce(CGFloat.zero) { sum, x in
                sum + rep.colorAt(x: x, y: 14 * 8)!.alphaComponent
                    + ((x < 3 * 8 || x > 29 * 8) ? rep.colorAt(x: x, y: 9 * 8)!.alphaComponent : 0)
            }
            amounts.append(amount)
        }
        for index in 1..<amounts.count { XCTAssertGreaterThan(amounts[index], amounts[index - 1]) }
    }

    private func render(_ image: NSImage, scale: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((image.size.width * CGFloat(scale)).rounded(.up)),
            pixelsHigh: Int((image.size.height * CGFloat(scale)).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func occupied(_ rep: NSBitmapImageRep, threshold: CGFloat = 0.02) -> [(x: Int, y: Int)] {
        (0..<rep.pixelsHigh).flatMap { y in
            (0..<rep.pixelsWide).compactMap { x in rep.colorAt(x: x, y: y)!.alphaComponent > threshold ? (x, y) : nil }
        }
    }

    private func edgeAlpha(_ rep: NSBitmapImageRep) -> CGFloat {
        (0..<rep.pixelsHigh).flatMap { y in
            [rep.colorAt(x: 0, y: y)!.alphaComponent, rep.colorAt(x: rep.pixelsWide - 1, y: y)!.alphaComponent]
        }.max() ?? 0
    }

    private func alphaSum(_ rep: NSBitmapImageRep) -> CGFloat {
        (0..<rep.pixelsHigh).reduce(0) { sum, y in
            sum + (0..<rep.pixelsWide).reduce(0) { $0 + rep.colorAt(x: $1, y: y)!.alphaComponent }
        }
    }

    private func pixels(_ image: NSImage) -> Data {
        let rep = render(image, scale: 2)
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }
}
