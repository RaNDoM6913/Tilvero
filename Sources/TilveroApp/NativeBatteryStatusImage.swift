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

/// Original AppKit paths approximate the supplied macOS silhouette. The inside
/// mode is deliberately custom and iOS-inspired. Template alpha, including text
/// cutouts, lets the status bar adapt both modes to its actual appearance.
@MainActor
enum NativeBatteryStatusImage {
    static func make(level: Int?, style: MenuBarDisplayStyle, externalPower: Bool, scale: CGFloat = 1, textSize: MenuBarTextSize = .larger) -> NSImage {
        let inside = style == .inside
        let canvas = NSSize(width: inside ? 35 : 27, height: 18)
        let factor = CGFloat(MenuBarSizing.validatedIconScale(Double(scale)))
        let size = NSSize(width: canvas.width * factor, height: canvas.height * factor)
        let level = ReadingPresentation.validLevel(level)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.translateX(by: rect.minX, yBy: rect.minY)
            transform.scaleX(by: rect.width / canvas.width, yBy: rect.height / canvas.height)
            transform.concat()
            if inside {
                drawInside(level: level, externalPower: externalPower, textSize: textSize)
            } else {
                drawNormal(level: level, externalPower: externalPower)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawNormal(level: Int?, externalPower: Bool) {
        // Owner reference including contour: 46×24 pixels at 2×. The path
        // is 22×11 pt because its 1 pt stroke also contributes to those bounds.
        let body = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: 22, height: 11), xRadius: 3.3, yRadius: 3.3)
        NSColor.black.withAlphaComponent(0.5).setStroke()
        body.lineWidth = 1
        body.stroke()
        NSColor.black.withAlphaComponent(0.5).setFill()
        NSBezierPath(roundedRect: NSRect(x: 24.5, y: 7, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()
        drawFill(level: level, in: NSRect(x: 3.25, y: 5, width: 18.5, height: 8), radius: 1.4)
        if level == nil {
            drawText("—", centeredAt: NSPoint(x: externalPower ? 7 : 12.5, y: 9), size: 8, operation: .sourceOver)
        }
        if externalPower {
            let bolt = boltPath(center: NSPoint(x: 13, y: 9), height: 10)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSColor.black.setStroke()
            bolt.lineWidth = 1.7
            bolt.lineJoinStyle = .round
            bolt.stroke()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.black.setFill()
            bolt.fill()
        }
    }

    private static func drawInside(level: Int?, externalPower: Bool, textSize: MenuBarTextSize) {
        let bodyRect = NSRect(x: 1.25, y: 3, width: 30, height: 12)
        NSColor.black.withAlphaComponent(0.2).setFill()
        NSBezierPath(roundedRect: bodyRect, xRadius: 4.2, yRadius: 4.2).fill()
        NSColor.black.withAlphaComponent(0.45).setFill()
        NSBezierPath(roundedRect: NSRect(x: 32.25, y: 7, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()
        drawFill(level: level, in: bodyRect, radius: 4.2)

        // Porter-Duff XOR makes digits dark on the unfilled track and clear
        // cutouts over opaque fill. A template therefore remains readable in
        // either status-bar appearance without inventing a full battery at 1%.
        drawText(level.map(String.init) ?? "—", centeredAt: NSPoint(x: externalPower ? 13 : 16.25, y: 9),
                 size: textSize == .system ? 11 : 12, operation: .xor)
        if externalPower {
            let markerSize = NSSize(width: 7, height: 12)
            let marker = NSImage(size: markerSize, flipped: false) { _ in
                NSColor.black.setFill()
                boltPath(center: NSPoint(x: 5.3, y: 6), height: 7.5).fill()
                return true
            }
            marker.draw(in: NSRect(x: 23.5, y: 3, width: markerSize.width, height: markerSize.height),
                        from: .zero, operation: .xor, fraction: 1)
        }
    }

    /// Clip a complete rounded reservoir by the exact observed fraction. No
    /// minimum sliver or quantized symbol bin stands in for the measured level.
    private static func drawFill(level: Int?, in rect: NSRect, radius: CGFloat) {
        guard let level, level > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(level) / 100, height: rect.height).clip()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawText(_ text: String, centeredAt point: NSPoint, size: CGFloat, operation: NSCompositingOperation) {
        let baseFont = NSFont.systemFont(ofSize: size, weight: .bold, width: .condensed)
        // Selecting the rounded design resets weight on some macOS releases.
        // Reapply traits so small status-bar digits retain their strong stems.
        let descriptor = baseFont.fontDescriptor.withDesign(.rounded)?.withSymbolicTraits([.bold, .condensed])
        let font = descriptor.flatMap { NSFont(descriptor: $0, size: size) } ?? baseFont
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let string = text as NSString
        let dimensions = string.size(withAttributes: attributes)
        let textImage = NSImage(size: dimensions, flipped: false) { _ in
            string.draw(at: .zero, withAttributes: attributes)
            return true
        }
        textImage.draw(in: NSRect(x: point.x - dimensions.width / 2, y: point.y - dimensions.height / 2,
                                 width: dimensions.width, height: dimensions.height),
                       from: .zero, operation: operation, fraction: 1)
    }

    /// A small original lightning path indicates adapter presence, independently
    /// of whether the battery is currently accepting charge.
    private static func boltPath(center: NSPoint, height: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        let vertices: [(CGFloat, CGFloat)] = [(0.18, 0.5), (-0.3, -0.05), (-0.02, -0.05), (-0.18, -0.5), (0.3, 0.09), (0.02, 0.09)]
        for (index, vertex) in vertices.enumerated() {
            let point = NSPoint(x: center.x + vertex.0 * height, y: center.y + vertex.1 * height)
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        path.close()
        return path
    }
}
