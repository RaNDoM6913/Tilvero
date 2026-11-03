import AppKit
import XCTest
@testable import TilveroApp

@MainActor final class SystemBatterySymbolTests: XCTestCase {
    func testModernSilhouettePreservesPublicNativeAlphaAtFullAndEmptyCharge() throws {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { return }
        for scale in [1, 2, 8] {
            let native = try XCTUnwrap(NSImage(systemSymbolName: "battery.100percent", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular)))
            let reference = NSImage(size: NSSize(width: 32, height: 24), flipped: false) { _ in
                native.draw(at: NSPoint(x: (32 - native.size.width) / 2, y: (24 - native.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            let expected = render(reference, scale: scale)
            for (level, opacity) in [(0, CGFloat(0.2)), (100, 1)] {
                let actual = render(try XCTUnwrap(SystemBatterySymbol.makeFilled(level: level, density: scale, contactOpacity: opacity)), scale: scale)
                for y in 0..<actual.pixelsHigh { for x in 0..<actual.pixelsWide {
                    XCTAssertEqual(actual.colorAt(x: x, y: y)!.alphaComponent,
                                   expected.colorAt(x: x, y: y)!.alphaComponent * opacity, accuracy: 1.0 / 255,
                                   "The public native silhouette and antialiasing must survive the measured-fill composition.")
                } }
            }
        }
    }
    func testModernNativeBodyKeepsContinuousObservedFillAndASeparateContact() throws {
        for scale in [1, 2, 8] {
            // The host's native filled topology is required only on macOS 27;
            // older hosts intentionally take the original-vector fallback.
            guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 else { continue }
            var totals: [CGFloat] = []
            for level in [0, 1, 10, 90, 99, 100] {
                let image = try XCTUnwrap(SystemBatterySymbol.makeFilled(level: level, density: scale))
                let rep = render(image, scale: scale)
                totals.append((0..<rep.pixelsHigh).reduce(0) { sum, y in
                    sum + (0..<rep.pixelsWide).reduce(0) { $0 + rep.colorAt(x: $1, y: y)!.alphaComponent }
                })
            }
            for i in 1..<totals.count { XCTAssertGreaterThan(totals[i], totals[i - 1], "Measured fill must not use quantized symbol bins or a minimum sliver.") }
            let empty = render(try XCTUnwrap(SystemBatterySymbol.makeFilled(level: 0, density: scale)), scale: scale)
            let full = render(try XCTUnwrap(SystemBatterySymbol.makeFilled(level: 100, density: scale)), scale: scale)
            for y in 0..<full.pixelsHigh { for x in 27 * scale..<full.pixelsWide {
                XCTAssertEqual(empty.colorAt(x: x, y: y)!.alphaComponent, full.colorAt(x: x, y: y)!.alphaComponent,
                               "The battery contact must not participate in measured fill.")
            } }
        }
    }

    private func render(_ image: NSImage, scale: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32 * scale, pixelsHigh: 24 * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 32, height: 24)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
