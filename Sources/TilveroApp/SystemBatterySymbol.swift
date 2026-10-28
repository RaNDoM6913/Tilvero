import AppKit

/// Uses the public system glyph at runtime. Only its reservoir is clipped;
/// Apple's contour, lightning, halo and antialiasing remain native pixels.
@MainActor enum SystemBatterySymbol {
    private struct Component {
        var pixels: [Int]
        var bounds: CGRect
    }
    private struct Layers {
        let alpha: [UInt8]
        let plainFill: [UInt8]?
        let roles: [UInt8] // 0 contour/contact, 1 reservoir, 2 native lightning
        let reservoir: ClosedRange<Int>
        let width: Int
        let height: Int
    }
    private static var cache: [Int: Layers] = [:]

    static func make(level: Int, adapter: Bool, density: Int, contourOpacity: CGFloat = 0.5) -> NSImage? {
        let scale = min(8, max(1, density)), key = scale * 2 + (adapter ? 1 : 0)
        let layers: Layers
        if let existing = cache[key] { layers = existing }
        else {
            guard let value = prepare(adapter: adapter, density: scale) else { return nil }
            cache[key] = value; layers = value
        }
        guard let rep = bitmap(density: scale), let data = rep.bitmapData else { return nil }
        let fraction = CGFloat(min(100, max(0, level))) / 100
        let edge = CGFloat(layers.reservoir.lowerBound) + CGFloat(layers.reservoir.count) * fraction
        for y in 0..<layers.height { for x in 0..<layers.width {
            let i = y * layers.width + x
            let multiplier: CGFloat
            switch layers.roles[i] {
            case 1: multiplier = min(1, max(0, edge - CGFloat(x)))
            case 2: multiplier = 1
            default: multiplier = contourOpacity
            }
            let offset = y * rep.bytesPerRow + x * 4
            data[offset] = 0; data[offset + 1] = 0; data[offset + 2] = 0
            if let plainFill = layers.plainFill {
                let fill = CGFloat(plainFill[i]) * min(1, max(0, edge - CGFloat(x)))
                data[offset + 3] = UInt8(min(255, (CGFloat(layers.alpha[i]) * contourOpacity + fill).rounded()))
            } else { data[offset + 3] = UInt8((CGFloat(layers.alpha[i]) * multiplier).rounded()) }
        } }
        let image = NSImage(size: NSSize(width: 32, height: 24)); image.addRepresentation(rep)
        return image
    }

    private static func prepare(adapter: Bool, density: Int) -> Layers? {
        _ = NSApplication.shared
        guard let empty = raster("battery.0percent", density: density),
              let full = raster("battery.100percent", density: density),
              let source = adapter ? raster("battery.100percent.bolt", density: density) : full else { return nil }
        let width = 32 * density, height = 24 * density
        let emptyParts = components(empty, width: width, height: height)
        guard emptyParts.count == 2, let body = emptyParts.max(by: { $0.pixels.count < $1.pixels.count })?.bounds else { return nil }
        let reservoirPixels = full.indices.filter { Int(full[$0]) > Int(empty[$0]) + 1 }
        guard let left = reservoirPixels.map({ $0 % width }).min(), let right = reservoirPixels.map({ $0 % width }).max(), right > left else { return nil }
        if !adapter {
            // At 1x the native filled reservoir can touch the outline's solid
            // core. Alpha subtraction preserves both rather than assuming three
            // disconnected components. At full opacity E + (F - E) is exactly F.
            guard full.indices.allSatisfy({ full[$0] >= empty[$0] }) else { return nil }
            return .init(alpha: empty, plainFill: full.indices.map { full[$0] - empty[$0] },
                         roles: [UInt8](repeating: 0, count: source.count), reservoir: left...right, width: width, height: height)
        }
        let parts = components(source, width: width, height: height)
        guard parts.count == (adapter ? 6 : 3) else { return nil }
        let fills = parts.indices.filter {
            let box = parts[$0].bounds
            return box.height < body.height - CGFloat(2 * density) && box.minX > body.minX + CGFloat(density)
                && box.maxX < body.maxX - CGFloat(density) && box.minY > body.minY + CGFloat(density)
                && box.maxY < body.maxY - CGFloat(density)
        }
        guard fills.count == (adapter ? 2 : 1) else { return nil }
        let bolt = adapter ? parts.indices.filter { !fills.contains($0) && parts[$0].bounds.height >= body.height - CGFloat(density) }
            .min(by: { abs(parts[$0].bounds.midX - body.midX) < abs(parts[$1].bounds.midX - body.midX) }) : nil
        guard !adapter || bolt != nil else { return nil }
        var owner = [Int](repeating: -1, count: source.count)
        for (index, part) in parts.enumerated() { for pixel in part.pixels { owner[pixel] = index } }
        var roles = [UInt8](repeating: 0, count: source.count)
        for i in source.indices where source[i] > 0 {
            var selected = owner[i]
            if selected < 0 {
                let x = i % width, y = i / width
                var nearest = Int.max
                // Only the fringe needs classification; solid cores keep their
                // original role. Assign, rather than discard, native AA pixels.
                for (index, part) in parts.enumerated() { for pixel in part.pixels {
                    let dx = x - pixel % width, dy = y - pixel / width, distance = dx * dx + dy * dy
                    if distance < nearest { nearest = distance; selected = index }
                } }
            }
            roles[i] = fills.contains(selected) ? 1 : selected == bolt ? 2 : 0
        }
        return .init(alpha: source, plainFill: nil, roles: roles, reservoir: left...right, width: width, height: height)
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
    private static func bitmap(density: Int) -> NSBitmapImageRep? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32 * density, pixelsHigh: 24 * density,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 32 * density * 4, bitsPerPixel: 32)
        rep?.size = NSSize(width: 32, height: 24)
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
