import AppKit
import XCTest
@testable import TilveroApp

@MainActor
final class NativeBatteryStatusImageTests: XCTestCase {
    func testActiveAwakeAddsCupWithoutChangingBatteryMeasurementsOrCutouts() async throws {
        for style in MenuBarDisplayStyle.allCases {
            for ac in [false, true] {
                for level in [0, 1, 50, 100, nil] {
                    let original = NativeBatteryStatusImage.make(level: level, style: style, externalPower: ac)
                    let active = NativeBatteryStatusImage.make(level: level, style: style, externalPower: ac, awake: .active)
                    XCTAssertFalse(active.isTemplate)
                    let before = render(original, scale: 2), after = render(active, scale: 2)
                    for y in 0..<before.pixelsHigh { for x in 0..<before.pixelsWide {
                        XCTAssertEqual(before.colorAt(x: x, y: y)!.alphaComponent,
                                       after.colorAt(x: x, y: y)!.alphaComponent, accuracy: 0.02)
                    } }
                    let badge = occupied(after).filter { $0.x >= before.pixelsWide }
                    XCTAssertGreaterThan(badge.count, 20, "Awake must remain identifiable without color.")
                    let blue = after.colorAt(x: badge[0].x, y: badge[0].y)!.usingColorSpace(.deviceRGB)!
                    XCTAssertGreaterThan(blue.blueComponent, blue.redComponent + 0.25)
                    XCTAssertLessThan(edgeAlpha(after), 0.35)
                }
            }
        }
    }

    func testAwakeSelectedMaskAndUnconfirmedStayTemplateWithSeparateBadges() async throws {
        for style in MenuBarDisplayStyle.allCases {
            for scale in [CGFloat(0.85), 1, 1.15] {
                let active = NativeBatteryStatusImage.make(level: nil, style: style, externalPower: true, scale: scale, awake: .active)
                let selected = NativeBatteryStatusImage.make(level: nil, style: style, externalPower: true, scale: scale, awake: .active, highlighted: true)
                let uncertain = NativeBatteryStatusImage.make(level: nil, style: style, externalPower: true, scale: scale, awake: .unconfirmed)
                XCTAssertTrue(selected.isTemplate, "AppKit must adapt selected content to its highlight.")
                XCTAssertTrue(uncertain.isTemplate, "Unconfirmed ownership must never show active blue.")
                XCTAssertEqual(active.size, selected.size)
                XCTAssertEqual(active.size, uncertain.size)
                let first = render(active, scale: 2), second = render(selected, scale: 2)
                for y in 0..<first.pixelsHigh { for x in 0..<first.pixelsWide {
                    XCTAssertEqual(first.colorAt(x: x, y: y)!.alphaComponent,
                                   second.colorAt(x: x, y: y)!.alphaComponent, accuracy: 0.02)
                } }
                XCTAssertNotEqual(pixels(selected), pixels(uncertain), "Question and cup cannot claim the same state.")
            }
        }
        // Explicit opt-in fixture export; ordinary tests leave no render files.
        if let path = ProcessInfo.processInfo.environment["TILVERO_AWAKE_RENDER_DIR"] {
            let root = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for style in MenuBarDisplayStyle.allCases {
                for (name, state, selected) in [("off", KeepAwakeStatusIndicator.off, false), ("active", .active, false),
                                                ("selected-mask", .active, true), ("unconfirmed", .unconfirmed, false)] {
                    let image = NativeBatteryStatusImage.make(level: 80, style: style, externalPower: true, awake: state, highlighted: selected)
                    let data = try XCTUnwrap(render(image, scale: 4).representation(using: .png, properties: [:]))
                    try data.write(to: root.appendingPathComponent("\(style.rawValue)-\(name).png"))
                }
            }
        }
    }

    func testAwakeBindingUpdatesAfterStartReconcileStopAndUnconfirmedRelease() async throws {
        let driver = StatusAwakeFixture()
        let service = KeepAwakeService(driver: driver)
        var states: [KeepAwakeStatusIndicator] = []
        let binding = NativeKeepAwakeStatusBinding(service: service) { states.append($0) }
        XCTAssertEqual(states.last, .off)
        try service.startUntilStopped()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(states.last, .active)
        driver.failRead = true; driver.failRelease = true
        XCTAssertThrowsError(try service.reconcile())
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(states.last, .unconfirmed)
        driver.failRead = false; driver.failRelease = false
        try service.stop()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(states.last, .off)
        try service.startUntilStopped()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(states.last, .active)
        driver.assertion = nil
        try service.reconcile()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(states.last, .off)
        withExtendedLifetime(binding) {}
    }

    func testFailedStopCannotRemainActiveBlueEvenWhenServiceRetainsActiveFlag() async throws {
        let driver = StatusAwakeFixture()
        let running = KeepAwakeService(driver: driver)
        XCTAssertEqual(KeepAwakeStatusIndicator(service: running), .off)
        try running.startUntilStopped()
        driver.failRead = true; driver.failRelease = true
        XCTAssertThrowsError(try running.stop())
        XCTAssertTrue(running.isActive, "The service retains its last active flag when release fails.")
        XCTAssertEqual(KeepAwakeStatusIndicator(service: running), .unconfirmed)
        driver.failRead = false; driver.failRelease = false
        try running.stop()
        XCTAssertEqual(KeepAwakeStatusIndicator(service: running), .off)
    }

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

    func testModern90MatchesOwnerReferenceTypographyAndPowerCue() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return }
        // Owner's supplied 2× macOS 27 90 + AC screenshot, cropped to the
        // 29×18 pt canvas. Quantized alpha is estimated in linear sRGB from
        // the sampled backdrop and full fill, not copied into the runtime.
        // White ink implies a dark drawing context; the screenshot's original
        // appearance metadata is unavailable. This is not exact compositor proof.
        let reference = """
            0000000000000000000000000000000000000000000000000000000000
            0000000000000000000000000000000000000000000000000000000000
            0000000000000000000000000000000000000000000000000000000000
            0000000000000000000000000000000000000000000000000000000000
            0000000000000000000000000000000000000000000000000000000000
            0000000000000000000000000000000000000000000000000000000000
            00000015aceeffffffffffffffffffffffffffeeca5100000000000000
            000005efffffffffffffffffffffffffffffffffffff10000000000000
            00009fffffffffffffffffffffffffffffffffffffff32000000000000
            0005fffffffffffffffffffffeffffffffffffffffff33100000000000
            001effffff620014efffffe410018ffffffffff75fff33300000000000
            005ffffff30000001cffff3000000affffffff904fff33310000000000
            00afffff5001672003fff800164001effffffd00bfff33320000000000
            00cfffff201cfff300aff100dff6005fffffd102ffff33330000000000
            00efffff103ffffb005fd005fffe102fffff3009ffff33330040000000
            00effffe004ffffc003fa00affff301ffff4001dffff33330054000000
            00ffffff101efff5002f700dffff500fff900018889f33330055200000
            00ffffff40029b50001f500fffff700df9000000001f33330055400000
            00ffffffe1000000002f600effff500ef1000000009f33330055400000
            00fffffffd310005104f900bffff301ff988810009ff33330055200000
            00efffffffffccfd007fc007ffff102fffffd1004fff33330054000000
            00efffff212ffff300aff001fff9004fffff9003ffff33330040000000
            00cfffff4004ec5001fff5004d9100cfffff201dffff33330000000000
            00afffffd00000000affff10000006fffffb00dfffff33320000000000
            005ffffffc1000019fffffb100003ffffff409ffffff33310000000000
            001efffffffd99afffffffffa98cfffffff57fffffff33300000000000
            0005ffffffffffffffffffffffffffffffffffffffff33100000000000
            00009fffffffffffffffffffffffffffffffffffffff32000000000000
            000005efffffffffffffffffffffffffffffffffffff10000000000000
            00000015acefffffffffffffffffffffffffffeeca5100000000000000
            0000000000000000000000000000000000000000000000000000000000
            0000000000000000000000000000000000000000000000000000000000
            0000000000000000000000000000000000000000000000000000000000
            0000000000000000000000000000000000000000000000000000000000
            0000000000000000000000000000000000000000000000000000000000
            0000000000000000000000000000000000000000000000000000000000
            """.filter { !$0.isWhitespace }.map { CGFloat(Int(String($0), radix: 16)!) / 15 }
        let actual = render(NativeBatteryStatusImage.make(level: 90, style: .inside, externalPower: true,
                            textSize: .system, appearance: .macOS27), scale: 2, appearance: .darkAqua)
        XCTAssertEqual(reference.count, actual.pixelsWide * actual.pixelsHigh)
        func error(x: Range<Int>, y: Range<Int>) -> CGFloat {
            let differences = y.flatMap { yy in x.map { xx in
                abs(actual.colorAt(x: xx, y: yy)!.alphaComponent - reference[yy * 58 + xx])
            } }
            return differences.reduce(0, +) / CGFloat(differences.count)
        }
        XCTAssertLessThan(error(x: 6..<33, y: 9..<27), 0.12,
                          "The 90 reference has medium standard-width numerals, not bold condensed type.")
        XCTAssertLessThan(error(x: 33..<44, y: 9..<27), 0.10,
                          "The AC cue must retain the reference's painted size, baseline and gap.")
        XCTAssertLessThan(error(x: 0..<58, y: 0..<36), 0.045)
    }

    func testModern98MatchesTheSameReadingNativeReferenceTypographyAndContact() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return }
        // Same-value owner comparison: native 98 + AC at 2×. Relative mask
        // coverage uses that icon's own full-fill color and sampled backdrop in
        // linear sRGB. These small measured regions bound visual regressions;
        // Dark ink implies a light drawing context; original OS appearance
        // metadata is unavailable. This is not an exact compositor formula.
        let text = """
            ffffffffffffffffffffffffffff
            fffffecbdfffffffffecdeffffff
            ffff744445dfffffd544446effff
            fff649eec44efffe44beea45ffff
            ffd49ffffd48fffa4cffff94dfff
            ffa4dfffff54eff94effffc4cfff
            ff84efffff74effd4bffff84efff
            ffb4dfffff44dfff949dc74bffff
            ffe45efff944bffff74444affffe
            fffb44895494cffe449cc846fff9
            ffffc7447dc4eff54dffffb49ffe
            ffffffffff94ffe47ffffff44fff
            ffeceffffe45ffe47ffffff45fff
            ffe47ffff84bfff64cffffa49fff
            fff846ba547ffffd447ba646efff
            ffffa44449ffffffe854459fffff
            ffffffeeffffffffffffffffffff
            ffffffffffffffffffffffffffff
            """
        let contact = """
            010000
            0b4000
            0cc300
            0cc900
            0ccc00
            0ccc00
            0cc900
            0cc300
            0b4000
            010000
            """
        let actual = render(NativeBatteryStatusImage.make(level: 98, style: .inside, externalPower: true,
                            textSize: .system, appearance: .macOS27), scale: 2, appearance: .aqua)
        func error(_ reference: String, x: Range<Int>, y: Range<Int>) -> CGFloat {
            let coverage = reference.filter { !$0.isWhitespace }.map { CGFloat(Int(String($0), radix: 16)!) / 15 }
            let pixels = y.flatMap { yy in x.map { xx in actual.colorAt(x: xx, y: yy)!.alphaComponent } }
            XCTAssertEqual(coverage.count, pixels.count)
            return zip(coverage, pixels).reduce(0) { $0 + abs($1.0 - $1.1) } / CGFloat(pixels.count)
        }
        XCTAssertLessThan(error(text, x: 6..<34, y: 9..<27), 0.08,
                          "The same-reading native reference uses lighter numerals and secondary cutout coverage.")
        XCTAssertLessThan(error(contact, x: 49..<55, y: 13..<23), 0.10,
                          "The contact needs the native spacing and secondary coverage without changing the battery body.")
    }

    func testModernTwoDigitGeometryStaysFixedAsTheMeasuredReadingChanges() throws {
        for size in MenuBarTextSize.allCases {
            for ac in [false, true] {
                let baseline = NativeBatteryStatusImage.make(level: 90, style: .inside, externalPower: ac,
                    textSize: size, appearance: .macOS27)
                for level: Int? in (0...99).map(Optional.some) + [nil, -1, 101] {
                    let image = NativeBatteryStatusImage.make(level: level, style: .inside, externalPower: ac,
                        textSize: size, appearance: .macOS27)
                    XCTAssertEqual(image.size, baseline.size,
                        "A changing two-digit reading must not resize the status item or stretch its native battery body: \(String(describing: level)).")
                }
            }
        }
    }

    func testModernThreeDigitsKeepTheSameLegibleTypeSize() throws {
        for textSize in MenuBarTextSize.allCases {
            for ac in [false, true] {
                let two = NativeBatteryStatusImage.make(level: 90, style: .inside, externalPower: ac, textSize: textSize, appearance: .macOS27)
                let three = NativeBatteryStatusImage.make(level: 100, style: .inside, externalPower: ac, textSize: textSize, appearance: .macOS27)
                XCTAssertGreaterThan(three.size.width, two.size.width,
                                     "Reserve space for the extra digit instead of shrinking 100.")
                for scale in [1, 2] {
                    func cutoutHeight(_ image: NSImage, right: CGFloat) -> Int {
                        let rep = render(image, scale: scale)
                        let ys = (4 * scale..<14 * scale).filter { y in
                            // Include visible antialias coverage: regular 1× curves
                            // need not contain a near-transparent core on each row.
                            (4 * scale..<Int(right * CGFloat(scale))).contains { x in rep.colorAt(x: x, y: y)!.alphaComponent < 0.6 }
                        }
                        return (ys.max() ?? 0) - (ys.min() ?? 0) + 1
                    }
                    // The interior ranges exclude reservoir corners, contact and
                    // the independent AC cue. Compare actual painted cap height.
                    let twoRight: CGFloat = ac ? 16 : 20
                    let threeRight = twoRight + three.size.width - two.size.width
                    let twoHeight = cutoutHeight(two, right: twoRight)
                    XCTAssertGreaterThanOrEqual(twoHeight, 6 * scale - 1)
                    XCTAssertEqual(cutoutHeight(three, right: threeRight), twoHeight, accuracy: 1,
                                   "\(textSize), AC \(ac), backing scale \(scale)")
                }
            }
        }
    }

    func testModernAppearanceFitsEveryMeasuredAndUnavailableStateAtSupportedScales() throws {
        for style in MenuBarDisplayStyle.allCases {
            for ac in [false, true] {
                for scale in [CGFloat(0.85), 1, 1.15] {
                    let zero = NativeBatteryStatusImage.make(level: 0, style: style, externalPower: ac, scale: scale, appearance: .macOS27)
                    let unknown = NativeBatteryStatusImage.make(level: nil, style: style, externalPower: ac, scale: scale, appearance: .macOS27)
                    XCTAssertNotEqual(pixels(zero), pixels(unknown), "Unavailable data must never become a measured zero.")
                    for invalid in [-1, 101] {
                        XCTAssertEqual(pixels(NativeBatteryStatusImage.make(level: invalid, style: style, externalPower: ac, scale: scale, appearance: .macOS27)), pixels(unknown))
                    }
                    for level in [0, 10, 90, 100, nil] {
                        let image = NativeBatteryStatusImage.make(level: level, style: style, externalPower: ac, scale: scale, appearance: .macOS27)
                        for backingScale in [1, 2] {
                            let rep = render(image, scale: backingScale)
                            let ink = occupied(rep)
                            XCTAssertFalse(ink.isEmpty)
                            XCTAssertTrue(ink.allSatisfy { $0.y > 0 && $0.y < rep.pixelsHigh - 1 })
                            XCTAssertLessThan(edgeAlpha(rep), 0.35, "Native contact, numerals and adapter cue must fit the status canvas.")
                        }
                    }
                }
            }
        }
        let modern = NativeBatteryStatusImage.make(level: 90, style: .inside, externalPower: true, appearance: .macOS27)
        let legacy = NativeBatteryStatusImage.make(level: 90, style: .inside, externalPower: true, appearance: .macOS26)
        XCTAssertLessThan(modern.size.width, legacy.size.width, "The selected compact macOS 27 reference must not inherit the elongated iOS-inspired body.")
        XCTAssertNotEqual(pixels(modern), pixels(legacy))
    }

    func testModernNumeralsAndAdapterHaveContrastingCutoutsAndAVisibleGap() throws {
        for size in MenuBarTextSize.allCases {
            let full = render(NativeBatteryStatusImage.make(level: 100, style: .inside, externalPower: true, textSize: size, appearance: .macOS27), scale: 8, appearance: .darkAqua)
            let centre = (6 * 8..<12 * 8).flatMap { y in
                (5 * 8..<23 * 8).map { x in full.colorAt(x: x, y: y)!.alphaComponent }
            }
            XCTAssertGreaterThan(centre.filter { $0 < 0.1 }.count, centre.count / 10, "Full charge needs readable transparent numerals and a bolt.")
            XCTAssertGreaterThan(centre.filter { $0 > 0.9 }.count, centre.count / 3)
            // Find the actual numeral and cue cutouts rather than testing the
            // old fixed x=19, which is inside a digit after reserving 100's width.
            var remaining = Set((4 * 8..<14 * 8).flatMap { y in
                (3 * 8..<full.pixelsWide - 6 * 8).compactMap { x in
                    full.colorAt(x: x, y: y)!.alphaComponent < 0.3 ? y * full.pixelsWide + x : nil
                }
            })
            var components: [[Int]] = []
            while let first = remaining.first {
                remaining.remove(first)
                var component = [first], cursor = 0
                while cursor < component.count {
                    let pixel = component[cursor]; cursor += 1
                    for next in [pixel - 1, pixel + 1, pixel - full.pixelsWide, pixel + full.pixelsWide] where remaining.remove(next) != nil {
                        component.append(next)
                    }
                }
                // Discard tiny corner fringes outside the text/cue's interior.
                if component.count >= 8 * 8 { components.append(component) }
            }
            components.sort { ($0.map { $0 % full.pixelsWide }.min() ?? 0) < ($1.map { $0 % full.pixelsWide }.min() ?? 0) }
            XCTAssertEqual(components.count, 4, "100 and the AC cue must paint four independently legible shapes.")
            if components.count == 4 {
                let lastDigit = components[2].map { $0 % full.pixelsWide }.max()!
                let cue = components[3].map { $0 % full.pixelsWide }.min()!
                XCTAssertGreaterThanOrEqual(cue - lastDigit - 1, 4, "The final digit and AC cue need at least half a point of clear separation.")
            }
            let off = pixels(NativeBatteryStatusImage.make(level: 90, style: .inside, externalPower: false, textSize: size, appearance: .macOS27))
            let ac = pixels(NativeBatteryStatusImage.make(level: 90, style: .inside, externalPower: true, textSize: size, appearance: .macOS27))
            XCTAssertNotEqual(off, ac, "Adapter presence remains independent from the numeric battery reading.")
        }
    }

    func testModernSameImageAdaptsCutoutContrastWhenItsDrawingAppearanceChanges() throws {
        // Drawing-handler images may be cached. Reusing this exact image must
        // still follow its caller's appearance when a status item changes ink.
        for state in [KeepAwakeStatusIndicator.off, .active, .unconfirmed] {
            for selected in [false, true] {
                let image = NativeBatteryStatusImage.make(level: 98, style: .inside, externalPower: true,
                    textSize: .system, awake: state, highlighted: selected, appearance: .macOS27)
                let light = render(image, scale: 2, appearance: .aqua)
                let dark = render(image, scale: 2, appearance: .darkAqua)
                let repeated = render(image, scale: 2, appearance: .aqua)
                let changed = (0..<light.pixelsHigh).flatMap { y in
                    (0..<light.pixelsWide).map { x in
                        abs(light.colorAt(x: x, y: y)!.alphaComponent - dark.colorAt(x: x, y: y)!.alphaComponent)
                    }
                }
                XCTAssertGreaterThan(changed.filter { $0 > 0.1 }.count, 20,
                                     "The same cached image must adapt its numeral and AC cutouts to the current drawing appearance.")
                for y in 0..<light.pixelsHigh { for x in 0..<light.pixelsWide {
                    XCTAssertEqual(light.colorAt(x: x, y: y), repeated.colorAt(x: x, y: y),
                                   "Returning to the first appearance must not retain the previous cached mask.")
                } }
                XCTAssertEqual(image.isTemplate, state != .active || selected)
                for name in [NSAppearance.Name.aqua, .darkAqua] {
                    let unknown = NativeBatteryStatusImage.make(level: nil, style: .inside, externalPower: true,
                        textSize: .system, appearance: .macOS27)
                    let zero = NativeBatteryStatusImage.make(level: 0, style: .inside, externalPower: true,
                        textSize: .system, appearance: .macOS27)
                    XCTAssertNotEqual(pixels(unknown, appearance: name), pixels(zero, appearance: name),
                                      "Appearance adaptation must not erase unavailable versus measured zero.")
                }
            }
        }
    }

    func testModernAwakeBlueAndSelectedMaskPreserveTheSameBatteryAlpha() throws {
        for style in MenuBarDisplayStyle.allCases {
            let off = NativeBatteryStatusImage.make(level: 90, style: style, externalPower: true, appearance: .macOS27)
            let active = NativeBatteryStatusImage.make(level: 90, style: style, externalPower: true, awake: .active, appearance: .macOS27)
            let selected = NativeBatteryStatusImage.make(level: 90, style: style, externalPower: true, awake: .active, highlighted: true, appearance: .macOS27)
            let unconfirmed = NativeBatteryStatusImage.make(level: 90, style: style, externalPower: true, awake: .unconfirmed, appearance: .macOS27)
            XCTAssertFalse(active.isTemplate)
            XCTAssertTrue(selected.isTemplate)
            XCTAssertTrue(unconfirmed.isTemplate)
            let a = render(off, scale: 2), b = render(active, scale: 2), c = render(selected, scale: 2)
            for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide {
                XCTAssertEqual(a.colorAt(x: x, y: y)!.alphaComponent, b.colorAt(x: x, y: y)!.alphaComponent, accuracy: 0.02)
                XCTAssertEqual(b.colorAt(x: x, y: y)!.alphaComponent, c.colorAt(x: x, y: y)!.alphaComponent, accuracy: 0.02)
            } }
            XCTAssertNotEqual(pixels(selected), pixels(unconfirmed))
        }
    }

    func testExportNativeAppearanceComparisonWhenExplicitlyRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["TILVERO_BATTERY_RENDER_DIR"] else { return }
        let root = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for appearance in MenuBarBatteryAppearance.allCases {
            for style in MenuBarDisplayStyle.allCases {
                for ac in [false, true] {
                    for level in [0, 10, 90, 100, nil] {
                        let image = NativeBatteryStatusImage.make(level: level, style: style, externalPower: ac, textSize: .system, appearance: appearance)
                        let data = try XCTUnwrap(render(image, scale: 8).representation(using: .png, properties: [:]))
                        try data.write(to: root.appendingPathComponent("\(appearance.rawValue)-\(style.rawValue)-\(ac ? "ac" : "battery")-\(level.map(String.init) ?? "unknown").png"))
                    }
                }
            }
        }
    }

    private func render(_ image: NSImage, scale: Int, appearance: NSAppearance.Name? = nil) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((image.size.width * CGFloat(scale)).rounded(.up)),
            pixelsHigh: Int((image.size.height * CGFloat(scale)).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = image.size
        let draw = {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
        }
        if let appearance { NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance(draw) }
        else { draw() }
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

    private func pixels(_ image: NSImage, appearance: NSAppearance.Name? = nil) -> Data {
        let rep = render(image, scale: 2, appearance: appearance)
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }
}

@MainActor private final class StatusAwakeFixture: KeepAwakeTransport {
    var assertion: KeepAwakeAssertion?
    var failRead = false
    var failRelease = false
    func create(seconds: Int, name: String) throws -> UInt32 {
        assertion = .init(name: name, kind: "PreventUserIdleSystemSleep", active: true, seconds: seconds, releasesOnTimeout: true)
        return 7
    }
    func createUntilStopped(name: String) throws -> UInt32 {
        assertion = .init(name: name, kind: "PreventUserIdleSystemSleep", active: true, seconds: nil, releasesOnTimeout: true)
        return 7
    }
    func setTimeout(_ id: UInt32, seconds: Int, name: String) throws { throw KeepAwakeError.updateFailed }
    func read(_ id: UInt32) throws -> KeepAwakeAssertion? {
        if failRead { throw KeepAwakeError.unconfirmed }
        return assertion
    }
    func release(_ id: UInt32, name: String) throws {
        if failRelease { throw KeepAwakeError.releaseFailed }
        assertion = nil
    }
}
