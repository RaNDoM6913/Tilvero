import AppKit

/// Presentation shared by the status button and offline fixtures. The title is
/// formatted independently of the measured percentage used to draw the battery.
@MainActor
enum NativeStatusPresentation {
    static var font: NSFont { NSFont.menuBarFont(ofSize: 0) }

    static func font(for size: MenuBarTextSize) -> NSFont {
        switch size {
        // The local native reference paints approximately 63×16 physical pixels
        // at 2×; the 11 pt system face matches that reference's text metrics.
        case .system: NSFont.menuBarFont(ofSize: 11)
        case .larger: font
        }
    }

    static func percentageTitle(level: Int?, locale: Locale = .current) -> String {
        guard let level = ReadingPresentation.validLevel(level) else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: Double(level) / 100)) ?? "—"
    }
}

/// Uses public SF Symbols for the shell, terminal and AC bolt. Battery symbols
/// do not support variable fill on the installed OS, so the fill is composed from
/// their public template masks. No private asset or captured screen pixel is used.
@MainActor
enum NativeBatteryStatusImage {
    private static let canvas = NSSize(width: 27, height: 18)
    private static let maskScale = 8
    private static let glyphs = Glyphs.make()

    static func make(level: Int?, style: MenuBarDisplayStyle, externalPower: Bool, scale: CGFloat = 1, textSize: MenuBarTextSize = .larger) -> NSImage {
        let original = makeUnscaled(level: level, style: style, externalPower: externalPower, textSize: textSize)
        let factor = CGFloat(MenuBarSizing.validatedIconScale(Double(scale)))
        guard factor != 1 else { return original }
        let image = NSImage(size: NSSize(width: original.size.width * factor, height: original.size.height * factor), flipped: false) { rect in
            original.draw(in: rect, from: NSRect(origin: .zero, size: original.size), operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func makeUnscaled(level: Int?, style: MenuBarDisplayStyle, externalPower: Bool, textSize: MenuBarTextSize) -> NSImage {
        let level = ReadingPresentation.validLevel(level)
        let inside = style == .inside
        let extraWidth: CGFloat = inside ? 16 : 0
        let size = NSSize(width: canvas.width + extraWidth, height: canvas.height)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let glyphs else {
                // An OS symbol failure is an unavailable indicator, never zero.
                drawText("?", centeredAt: NSPoint(x: rect.midX, y: rect.midY), size: 11)
                return true
            }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let scale = rect.width / size.width
            let transform = NSAffineTransform()
            transform.translateX(by: rect.minX, yBy: rect.minY)
            transform.scale(by: scale)
            transform.concat()

            // Keep the normal fully charged AC symbol entirely OS drawn.
            if level == 100 && externalPower && !inside {
                glyphs.charged.draw(in: NSRect(origin: .zero, size: canvas))
                return true
            }
            let fullRect = NSRect(origin: .zero, size: size)
            if let level, level > 0 {
                NSGraphicsContext.saveGraphicsState()
                let fillWidth = (glyphs.fillBounds.width + extraWidth) * CGFloat(level) / 100
                NSRect(x: glyphs.fillBounds.minX, y: 0, width: fillWidth, height: size.height).clip()
                drawStretched(glyphs.fill, in: fullRect, extraWidth: extraWidth, fraction: inside ? 0.18 : 1)
                NSGraphicsContext.restoreGraphicsState()
            }
            drawStretched(glyphs.empty, in: fullRect, extraWidth: extraWidth)
            if externalPower {
                let boltRect = NSRect(x: extraWidth, y: 0, width: canvas.width, height: canvas.height)
                glyphs.halo.draw(in: boltRect, from: .zero, operation: .destinationOut, fraction: 1)
                glyphs.bolt.draw(in: boltRect)
            }
            if inside || level == nil {
                // Inside percentage is a custom layout, with space reserved for
                // the AC bolt; it is not a native macOS percentage-inside variant.
                let x: CGFloat = externalPower ? (inside ? 11.5 : 5) : (size.width - 2) / 2
                drawText(level.map(String.init) ?? "—", centeredAt: NSPoint(x: x, y: 9), size: inside ? (textSize == .system ? 7 : 8) : 5)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawText(_ text: String, centeredAt point: NSPoint, size: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        let string = text as NSString
        let dimensions = string.size(withAttributes: attributes)
        string.draw(at: NSPoint(x: point.x - dimensions.width / 2, y: point.y - dimensions.height / 2), withAttributes: attributes)
    }

    /// Stretch only the middle of the battery. Corners and terminal retain their
    /// native dimensions in the explicitly custom percentage-inside mode.
    private static func drawStretched(_ image: NSImage, in rect: NSRect, extraWidth: CGFloat, fraction: CGFloat = 1) {
        guard extraWidth > 0 else {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction)
            return
        }
        for (sourceX, sourceWidth, targetX, targetWidth) in [
            (CGFloat(0), CGFloat(8), CGFloat(0), CGFloat(8)),
            (8, canvas.width - 16, 8, canvas.width - 16 + extraWidth),
            (canvas.width - 8, 8, canvas.width - 8 + extraWidth, 8)
        ] {
            image.draw(in: NSRect(x: targetX, y: 0, width: targetWidth, height: canvas.height),
                       from: NSRect(x: sourceX, y: 0, width: sourceWidth, height: canvas.height),
                       operation: .sourceOver, fraction: fraction)
        }
    }

    @MainActor
    private struct Glyphs {
        let empty: NSImage
        let charged: NSImage
        let fill: NSImage
        let halo: NSImage
        let bolt: NSImage
        let fillBounds: NSRect

        static func make() -> Glyphs? {
            let configuration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular, scale: .medium)
                .applying(.preferringMonochrome())
            func symbol(_ name: String) -> NSImage? {
                NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
            }
            guard let outline = symbol("battery.0percent"), let full = symbol("battery.100percent"),
                  let charging = symbol("battery.100percent.bolt"),
                  let empty = raster(outline), let filled = raster(full), let charged = raster(charging) else { return nil }
            let width = empty.pixelsWide, height = empty.pixelsHigh
            let count = width * height
            let a = alpha(filled), e = alpha(empty), b = alpha(charged)
            let fillAlpha = (0..<count).map { UInt8(max(0, Int(a[$0]) - Int(e[$0]))) }
            let haloAlpha = (0..<count).map { UInt8(max(0, Int(a[$0]) - Int(b[$0]))) }

            // The native bolt is isolated from the battery fill by its clear
            // halo. Recover that connected component from the public template.
            let center = (height / 2) * width + width / 2
            guard b[center] > 0 else { return nil }
            var seen = [Bool](repeating: false, count: count)
            var stack = [center]
            seen[center] = true
            while let index = stack.popLast() {
                let x = index % width, y = index / width
                for dy in -1...1 { for dx in -1...1 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let next = ny * width + nx
                    if !seen[next] && b[next] > 0 { seen[next] = true; stack.append(next) }
                } }
            }
            // If a future symbol joins the bolt to its shell, do not silently
            // treat the entire filled battery as a power marker.
            let boltCount = seen.filter { $0 }.count
            guard boltCount > 0, boltCount < count / 3,
                  let fillBounds = bounds(fillAlpha, width: width, height: height) else { return nil }
            let boltAlpha = (0..<count).map { seen[$0] ? b[$0] : 0 }
            return Glyphs(empty: image(empty), charged: image(charged),
                          fill: mask(fillAlpha, width: width, height: height),
                          halo: mask(haloAlpha, width: width, height: height),
                          bolt: mask(boltAlpha, width: width, height: height), fillBounds: fillBounds)
        }

        private static func raster(_ symbol: NSImage) -> NSBitmapImageRep? {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: Int(canvas.width) * maskScale, pixelsHigh: Int(canvas.height) * maskScale,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
            rep.size = canvas
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            symbol.isTemplate = true
            symbol.draw(in: NSRect(x: (canvas.width - symbol.size.width) / 2,
                                  y: (canvas.height - symbol.size.height) / 2,
                                  width: symbol.size.width, height: symbol.size.height))
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }

        private static func alpha(_ rep: NSBitmapImageRep) -> [UInt8] {
            let bytes = rep.bitmapData!
            return (0..<(rep.pixelsWide * rep.pixelsHigh)).map { index in
                bytes[(index / rep.pixelsWide) * rep.bytesPerRow + (index % rep.pixelsWide) * 4 + 3]
            }
        }

        private static func image(_ rep: NSBitmapImageRep) -> NSImage {
            let image = NSImage(size: canvas)
            image.addRepresentation(rep)
            return image
        }

        private static func mask(_ alpha: [UInt8], width: Int, height: Int) -> NSImage {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            rep.size = canvas
            let bytes = rep.bitmapData!
            for index in alpha.indices {
                let offset = (index / width) * rep.bytesPerRow + (index % width) * 4
                bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0; bytes[offset + 3] = alpha[index]
            }
            return image(rep)
        }

        private static func bounds(_ alpha: [UInt8], width: Int, height: Int) -> NSRect? {
            let occupied = alpha.indices.filter { alpha[$0] > 0 }
            guard let minX = occupied.map({ $0 % width }).min(), let maxX = occupied.map({ $0 % width }).max(),
                  let minY = occupied.map({ $0 / width }).min(), let maxY = occupied.map({ $0 / width }).max() else { return nil }
            return NSRect(x: CGFloat(minX) / CGFloat(maskScale), y: CGFloat(height - maxY - 1) / CGFloat(maskScale),
                          width: CGFloat(maxX - minX + 1) / CGFloat(maskScale), height: CGFloat(maxY - minY + 1) / CGFloat(maskScale))
        }
    }
}
