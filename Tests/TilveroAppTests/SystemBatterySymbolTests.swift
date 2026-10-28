import AppKit
import XCTest
@testable import TilveroApp

@MainActor final class SystemBatterySymbolTests: XCTestCase {
    func testFullCompositionPreservesThePublicAppleGlyphAtBothBackingScales() throws {
        for scale in [1, 2] {
            for adapter in [false, true] {
                let actual = try XCTUnwrap(SystemBatterySymbol.make(level: 100, adapter: adapter, density: scale, contourOpacity: 1))
                let native = try XCTUnwrap(NSImage(systemSymbolName: adapter ? "battery.100percent.bolt" : "battery.100percent", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular)))
                let reference = NSImage(size: NSSize(width: 32, height: 24), flipped: false) { _ in
                    native.draw(at: NSPoint(x: (32 - native.size.width) / 2, y: (24 - native.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
                    return true
                }
                let a = render(actual, scale: scale), b = render(reference, scale: scale)
                for y in 0..<a.pixelsHigh { for x in 0..<a.pixelsWide {
                    XCTAssertEqual(a.colorAt(x: x, y: y)!.alphaComponent, b.colorAt(x: x, y: y)!.alphaComponent, accuracy: 1.0 / 255,
                                   "The native contour, lightning and antialiasing must be preserved.")
                } }
            }
        }
    }
    func testObservedFillIsContinuousAndDoesNotChangeTheNativeBolt() throws {
        for scale in [1, 2] {
            var amounts: [CGFloat] = []
            for level in [0, 1, 25, 50, 85, 100] {
                let image = try XCTUnwrap(SystemBatterySymbol.make(level: level, adapter: true, density: scale))
                let rep = render(image, scale: scale)
                amounts.append((0..<rep.pixelsHigh).reduce(0) { sum, y in sum + (0..<rep.pixelsWide).reduce(0) { $0 + rep.colorAt(x: $1, y: y)!.alphaComponent } })
            }
            for index in 1..<amounts.count { XCTAssertGreaterThanOrEqual(amounts[index], amounts[index - 1]) }
            XCTAssertGreaterThan(amounts[4], amounts[3])
            XCTAssertLessThan(amounts[4], amounts[5])
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
