// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit

/// Uses the public system glyph at runtime. Its filled silhouette and contact
/// stay native; continuous charge, numerals and adapter presence remain separate.
@MainActor enum SystemBatterySymbol {
    private struct Component {
        var pixels: [Int]
        var bounds: CGRect
    }
    private struct FilledLayers {
        let alpha: [UInt8]
        let body: CGRect
        let contactBoundary: CGFloat
        let width: Int
        let height: Int
    }
    private static var filledCache: [Int: FilledLayers] = [:]
    /// Right edge of the measured fill in points, measured from the left of the last image `makeFilled` returned.
    private(set) static var lastFillEdge: CGFloat = 0

    /// The macOS 27 public full-battery symbol is a filled body and a separate
    /// contact. Keep its exact native silhouette, including antialiasing, while
    /// clipping continuous measured fill. Numerals and the small adapter cue are
    /// composed by the caller because SF Symbols does not supply percentage text.
    static func makeFilled(level: Int?, density: Int, contactOpacity: CGFloat = 0.45, trackOpacity: CGFloat = 0.2, bodyExtension: Int = 0, contactInset: CGFloat = 0) -> NSImage? {
        let scale = min(8, max(1, density))
        let layers: FilledLayers
        if let cached = filledCache[scale] { layers = cached }
        else {
            guard let alpha = raster("battery.100percent", density: scale) else { return nil }
            let parts = components(alpha, width: 32 * scale, height: 24 * scale)
            // Older/unknown symbol topologies use the caller's original vector
            // fallback rather than mistaking a contour or bolt for the reservoir.
            guard parts.count == 2, let body = parts.max(by: { $0.pixels.count < $1.pixels.count })?.bounds,
                  let contact = parts.min(by: { $0.pixels.count < $1.pixels.count })?.bounds,
                  body.width > body.height * 1.5, contact.minX > body.maxX else { return nil }
            // Solid-core bounds exclude native AA. Split at the inter-component
            // gutter, then include every body fringe pixel in measured fill.
            let boundary = (body.maxX + contact.minX - 1) / 2
            let bodyPixels = alpha.indices.filter { alpha[$0] > 0 && CGFloat($0 % (32 * scale)) < boundary }
            guard let left = bodyPixels.map({ $0 % (32 * scale) }).min(),
                  let right = bodyPixels.map({ $0 % (32 * scale) }).max() else { return nil }
            let reservoir = CGRect(x: left, y: 0, width: right - left + 1, height: 24 * scale)
            layers = .init(alpha: alpha, body: reservoir, contactBoundary: boundary, width: 32 * scale, height: 24 * scale)
            filledCache[scale] = layers
        }
        // Extend only the solid centre column: native endcaps and the separate
        // contact keep their geometry for the explicit larger-text option.
        let extra = max(0, min(16, bodyExtension)) * scale
        // Keep public 1× pixel hinting: its body/contact AA fringes touch.
        // At Retina densities the inset translates the separate contact mask.
        let inset = scale >= 2 && contactInset.isFinite ? min(1, max(0, contactInset)) * CGFloat(scale) : 0
        let outputWidth = layers.width + extra
        guard let rep = bitmap(density: scale, extraWidth: extra / scale), let data = rep.bitmapData else { return nil }
        let edge = fillEdge(level: level, bodyMinX: layers.body.minX, bodyWidth: layers.body.width, extra: extra, scale: scale)
        lastFillEdge = edge / CGFloat(scale)
        let middle = Int(layers.body.midX.rounded())
        for y in 0..<layers.height { for x in 0..<outputWidth {
            let sourceX = x < middle ? x : x < middle + extra ? middle : x - extra
            let i = y * layers.width + sourceX
            let body = CGFloat(x) < layers.contactBoundary + CGFloat(extra)
            let coverage = level == nil ? 0 : min(1, max(0, edge - CGFloat(x)))
            let opacity: CGFloat = body ? trackOpacity + (1 - trackOpacity) * coverage : contactOpacity
            let offset = y * rep.bytesPerRow + x * 4
            data[offset] = 0; data[offset + 1] = 0; data[offset + 2] = 0
            let alpha: CGFloat
            if body { alpha = CGFloat(layers.alpha[i]) }
            else {
                let sampleX = CGFloat(sourceX) + inset
                let left = Int(floor(sampleX)), fraction = sampleX - CGFloat(left)
                if left >= 0 && left + 1 < layers.width {
                    let row = y * layers.width
                    alpha = CGFloat(layers.alpha[row + left]) * (1 - fraction)
                        + CGFloat(layers.alpha[row + left + 1]) * fraction
                } else { alpha = 0 }
            }
            data[offset + 3] = UInt8((alpha * opacity).rounded())
        } }
        let image = NSImage(size: rep.size); image.addRepresentation(rep)
        return image
    }

    /// Width in points that the native macOS 27 battery maps 0...100 % onto: the solid core of its glyph, 23 pt. The native
    /// fill ends on a whole point, not on the exact fraction. In the owner's side-by-side screenshots (2x, 21/28/43/63/69/76 %)
    /// the native edges sit at 5, 6, 10, 14, 16 and 17 pt from the body's left edge, and the older 90 % reference at 21 pt;
    /// that is `round(level * w)` for every w in 22.78...23.01. A continuous fill put 28 %, 63 % and 76 % 0.6 to 0.86 pt
    /// too far right.
    static let nativeFillPoints: CGFloat = 23

    /// Right edge of the fill in raster pixels: the measured level, rounded to a whole point of the native fill width the way
    /// the native battery does. 100 % always fills the whole body, and a charged battery never rounds down to an empty one
    /// (a level that would round to zero keeps its exact width instead).
    static func fillEdge(level: Int?, bodyMinX: CGFloat, bodyWidth: CGFloat, extra: Int, scale: Int) -> CGFloat {
        guard let level, level > 0 else { return bodyMinX }
        if level >= 100 { return bodyMinX + bodyWidth + CGFloat(extra) }
        let width = nativeFillPoints + CGFloat(extra) / CGFloat(scale)
        let exact = CGFloat(level) / 100 * width
        let points = exact.rounded()
        return bodyMinX + (points >= 1 ? points : exact) * CGFloat(scale)
    }

    private static func components(_ alpha: [UInt8], width: Int, height: Int) -> [Component] {
        var visited = [Bool](repeating: false, count: alpha.count), result: [Component] = []
        for start in alpha.indices where alpha[start] >= 128 && !visited[start] {
            var queue = [start], cursor = 0
            visited[start] = true
            var minX = width, minY = height, maxX = 0, maxY = 0
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1
                let x = i % width, y = i / width
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                for j in [x > 0 ? i - 1 : -1, x + 1 < width ? i + 1 : -1, y > 0 ? i - width : -1, y + 1 < height ? i + width : -1] {
                    if j >= 0 && !visited[j] && alpha[j] >= 128 { visited[j] = true; queue.append(j) }
                }
            }
            result.append(.init(pixels: queue, bounds: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)))
        }
        return result
    }
    private static func bitmap(density: Int, extraWidth: Int = 0) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: (32 + extraWidth) * density, pixelsHigh: 24 * density,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: (32 + extraWidth) * density * 4, bitsPerPixel: 32)
        rep?.size = NSSize(width: 32 + extraWidth, height: 24)
        return rep
    }
    private static func raster(_ name: String, density: Int) -> [UInt8]? {
        guard let native = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular)),
              let rep = bitmap(density: density) else { return nil }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        native.draw(at: NSPoint(x: (32 - native.size.width) / 2, y: (24 - native.size.height) / 2), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return (0..<rep.pixelsHigh).flatMap { y in (0..<rep.pixelsWide).map { x in UInt8((rep.colorAt(x: x, y: y)!.alphaComponent * 255).rounded()) } }
    }
}
