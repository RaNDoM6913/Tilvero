// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import Combine

/// Ownership alone is insufficient evidence that the assertion remains active.
enum KeepAwakeStatusIndicator: Equatable, Sendable {
    case off, active, unconfirmed

    @MainActor init(service: KeepAwakeService) {
        self = !service.hasOwnedAssertion ? .off : service.isActive && service.message == nil ? .active : .unconfirmed
    }

    @MainActor var accessibilitySuffix: String? {
        switch self {
        case .off: nil
        case .active: L10n.text("Keep Awake active")
        case .unconfirmed: L10n.text("Keep Awake state unconfirmed")
        }
    }
}

/// @Published sends before assigning its storage. Read the settled state on the
/// next main-actor turn, including failed Stop/reconcile, without a telemetry poll.
@MainActor final class NativeKeepAwakeStatusBinding {
    private var observation: AnyCancellable?
    init(service: KeepAwakeService, onChange: @escaping @MainActor (KeepAwakeStatusIndicator) -> Void) {
        onChange(.init(service: service))
        observation = service.objectWillChange.sink { [weak service] in
            Task { @MainActor in
                guard let service else { return }
                onChange(.init(service: service))
            }
        }
    }
}

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

/// macOS 27 uses the public native filled silhouette with continuous measured
/// fill. macOS 26 retains its original outline and iOS-inspired inside mode.
/// Template alpha, including text
/// cutouts, lets the status bar adapt both modes to its actual appearance. Only a
/// confirmed own Keep Awake session uses blue, with a separate monochrome cup.
@MainActor
enum NativeBatteryStatusImage {
    static func make(level: Int?, style: MenuBarDisplayStyle, externalPower: Bool, scale: CGFloat = 1, textSize: MenuBarTextSize = .larger,
                     awake: KeepAwakeStatusIndicator = .off, highlighted: Bool = false, appearance: MenuBarBatteryAppearance = .macOS26,
                     redWhenLow: Bool = false, awakeColor: NSColor = .systemBlue) -> NSImage {
        let inside = style == .inside
        let validLevel = ReadingPresentation.validLevel(level)
        let modernExtension = appearance == .macOS27 && inside ? modernBodyExtension(textSize: textSize) : 0
        let batteryWidth: CGFloat = appearance == .macOS27 ? 29 + CGFloat(modernExtension) : inside ? 35 : 27
        // macOS 27 body: a confirmed Keep Awake session turns only the measured fill blue; no badge, the plain canvas.
        // The macOS 26 outline keeps its cup badge and whole-icon blue.
        let tintedAwake = awake == .active && appearance == .macOS27
        let canvas = NSSize(width: batteryWidth + (awake == .off || tintedAwake ? 0 : 10), height: 18)
        let factor = CGFloat(MenuBarSizing.validatedIconScale(Double(scale)))
        let size = NSSize(width: canvas.width * factor, height: canvas.height * factor)
        let level = validLevel
        // Like the system indicator: a red fill at 20 % or less while running on battery. Only the modern (macOS 27)
        // body is composed this way; the pressed state keeps the plain template.
        let lowFill = redWhenLow && appearance == .macOS27 && !externalPower && (level.map { $0 <= lowChargeThreshold } ?? false)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let transform = NSAffineTransform()
            transform.translateX(by: rect.minX, yBy: rect.minY)
            transform.scaleX(by: rect.width / canvas.width, yBy: rect.height / canvas.height)
            transform.concat()
            var redRegion: NSRect?
            if appearance == .macOS27 {
                redRegion = drawModern(level: level, style: style, externalPower: externalPower, textSize: textSize, bodyExtension: modernExtension)
            } else if inside {
                drawInside(level: level, externalPower: externalPower, textSize: textSize)
            } else {
                drawNormal(level: level, externalPower: externalPower)
            }
            if awake != .off && !tintedAwake { drawAwakeBadge(awake, x: batteryWidth + 1) }
            if tintedAwake {
                (isDarkInk ? NSColor.white : NSColor.black).setFill()
                NSRect(origin: .zero, size: canvas).fill(using: .sourceIn)
                if let region = redRegion { awakeColor.setFill(); region.fill(using: .sourceAtop) }
            } else if awake == .active && !tintedAwake && !highlighted {
                // Tint the existing alpha mask; measured fill and numeral/bolt
                // cutouts remain identical to the native template presentation.
                NSColor.systemBlue.setFill()
                NSRect(origin: .zero, size: canvas).fill(using: .sourceIn)
            } else if lowFill {
                // Not a template: resolve the ink here, in the status button's appearance.
                (isDarkInk ? NSColor.white : NSColor.black).setFill()
                NSRect(origin: .zero, size: canvas).fill(using: .sourceIn)
            }
            if lowFill, let region = redRegion {
                // sourceAtop keeps the numeral cutouts and the antialiased silhouette of the fill.
                NSColor.systemRed.setFill()
                region.fill(using: .sourceAtop)
            }
            return true
        }
        // The fill colours stay while the menu is open (pressed): the quick menu is where the user starts these modes.
        image.isTemplate = (awake != .active && !lowFill) || (highlighted && !tintedAwake && !lowFill)
        if tintedAwake { image.isTemplate = false }
        return image
    }

    private static func drawAwakeBadge(_ state: KeepAwakeStatusIndicator, x: CGFloat) {
        NSColor.black.setStroke()
        NSColor.black.setFill()
        if state == .unconfirmed {
            let circle = NSBezierPath(ovalIn: NSRect(x: x + 0.5, y: 5.25, width: 7, height: 7))
            circle.lineWidth = 1; circle.stroke()
            drawText("?", centeredAt: NSPoint(x: x + 4, y: 8.8), size: 6, operation: .sourceOver)
            return
        }
        // Original cup and steam. A dedicated strip preserves charging and
        // percentage semantics rather than replacing them with an Awake cue.
        let cup = NSBezierPath(roundedRect: NSRect(x: x + 0.5, y: 5.5, width: 5.5, height: 5), xRadius: 1.1, yRadius: 1.1)
        cup.lineWidth = 1; cup.stroke()
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: x + 6, y: 9.5))
        handle.curve(to: NSPoint(x: x + 6, y: 6.5), controlPoint1: NSPoint(x: x + 8, y: 10), controlPoint2: NSPoint(x: x + 8, y: 6))
        handle.lineWidth = 1; handle.stroke()
        let details = NSBezierPath()
        details.move(to: NSPoint(x: x, y: 4)); details.line(to: NSPoint(x: x + 7.5, y: 4))
        for offset: CGFloat in [1.5, 4.5] {
            details.move(to: NSPoint(x: x + offset, y: 12))
            details.curve(to: NSPoint(x: x + offset, y: 14.5), controlPoint1: NSPoint(x: x + offset - 1, y: 13), controlPoint2: NSPoint(x: x + offset + 1, y: 13.5))
        }
        details.lineWidth = 1; details.lineCapStyle = .round; details.stroke()
    }

    private static func drawNormal(level: Int?, externalPower: Bool) {
        // Runtime SF Symbols change with the OS. This original vector preserves
        // the owner's macOS 26 appearance even while running macOS 27.
        drawFallbackNormal(level: level, externalPower: externalPower)
    }

    private static func modernFont(_ size: MenuBarTextSize, compactFullCharge: Bool = false) -> NSFont {
        // The native 100 reference fits smaller public system numerals into the
        // same body. Preserve the measured 0...99 typography independently.
        let pointSize: CGFloat = compactFullCharge ? (size == .system ? 9.25 : 10.25) : (size == .system ? 10 : 11)
        return NSFont.systemFont(ofSize: pointSize, weight: .medium)
    }

    private static let modernTwoDigitCapacity: [MenuBarTextSize: CGFloat] =
        Dictionary(uniqueKeysWithValues: MenuBarTextSize.allCases.map { size in
            let font = modernFont(size)
            let capacity = (0...99).reduce(CGFloat.zero) { width, value in
                max(width, (String(value) as NSString).size(withAttributes: [.font: font]).width)
            }
            return (size, capacity)
        })

    private static func modernBodyExtension(textSize: MenuBarTextSize) -> Int {
        // Only the explicit larger-text option reserves additional space. Full
        // charge keeps the same native body as every other measured reading.
        max(0, Int(ceil(modernTwoDigitCapacity[textSize]! - modernTwoDigitCapacity[.system]!)))
    }

    private static var modernContactOpacity: CGFloat {
        // The owner's dark- and light-ink references have different secondary
        // contact coverage. Resolve it at draw time, like the numeral cutouts.
        isDarkInk ? 0.55 : 0.8
    }

    private static var isDarkInk: Bool { NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// White ink on a dark menu bar: the native unfilled track is about half as bright as the fill and the
    /// numeral/bolt are cut clean through both, so they read dark on the fill and on the track alike.
    private static var modernTrackOpacity: CGFloat { isDarkInk ? 0.5 : 0.2 }
    private static var modernCutoutOperation: NSCompositingOperation { isDarkInk ? .destinationOut : .xor }

    private static var modernCutoutOpacity: CGFloat {
        // The supplied dark-ink reference uses secondary numeral/cue coverage;
        // white ink retains clear cutouts. Read the active drawing context so
        // the same cached status image can adapt without a global theme change.
        NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? 1 : 0.75
    }

    /// Charge at or below which the fill turns red on battery power (the system indicator does the same).
    static let lowChargeThreshold = 20

    /// Returns the rectangle of the measured fill (canvas coordinates) when the native symbol was used.
    @discardableResult
    private static func drawModern(level: Int?, style: MenuBarDisplayStyle, externalPower: Bool, textSize: MenuBarTextSize, bodyExtension: Int) -> NSRect? {
        var fillRegion: NSRect?
        let extra = CGFloat(bodyExtension)
        let compactFullCharge = style == .inside && level == 100
        let density = max(1, min(8, Int((NSGraphicsContext.current?.cgContext.ctm.a ?? 2).magnitude.rounded())))
        if let native = SystemBatterySymbol.makeFilled(level: level, density: density, contactOpacity: modernContactOpacity, trackOpacity: modernTrackOpacity, bodyExtension: bodyExtension, contactInset: 0.5) {
            let offset = floor(1.5 * CGFloat(density)) / CGFloat(density)
            native.draw(at: NSPoint(x: -offset, y: -3), from: .zero, operation: .sourceOver, fraction: 1)
            fillRegion = NSRect(x: -offset, y: 0, width: SystemBatterySymbol.lastFillEdge, height: 18)
        } else {
            let body = NSRect(x: 1, y: 3, width: 23 + extra, height: 12)
            NSColor.black.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: body, xRadius: 3.5, yRadius: 3.5).fill()
            drawFill(level: level, in: body, radius: 3.5)
            NSColor.black.withAlphaComponent(modernContactOpacity).setFill()
            NSBezierPath(roundedRect: NSRect(x: 25 + extra, y: 7, width: 1.5, height: 4), xRadius: 0.75, yRadius: 0.75).fill()
        }
        if style == .inside {
            drawModernText(level.map(String.init) ?? "—", centeredAt: NSPoint(x: (externalPower ? (compactFullCharge ? 10.5 : 10) : 12.5) + extra / 2, y: 9),
                           font: modernFont(textSize, compactFullCharge: compactFullCharge))
        } else if level == nil {
            drawModernText("—", centeredAt: NSPoint(x: externalPower ? 10 : 12.5, y: 9), font: modernFont(textSize))
        }
        if externalPower {
            guard let marker = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: compactFullCharge ? 6 : 7.5, weight: .regular)) else { return fillRegion }
            let centreX: CGFloat = style == .inside || level == nil ? (compactFullCharge ? 21 : 19.5) + extra : 12.5
            let centreY: CGFloat = compactFullCharge ? 9 : 9.25
            marker.draw(at: NSPoint(x: centreX - marker.size.width / 2, y: centreY - marker.size.height / 2),
                        from: .zero, operation: modernCutoutOperation, fraction: modernCutoutOpacity)
        }
        return fillRegion
    }

    private static func drawModernText(_ value: String, centeredAt point: NSPoint, font: NSFont) {
        let string = value as NSString
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        var dimensions = string.size(withAttributes: attributes)
        if value == "100" {
            // Match the native compact numeral spacing without distorting glyphs.
            // Center by the two inter-digit gaps, excluding NSString's trailing kern.
            let tracking = -0.5 * font.pointSize / 9.25
            attributes[.kern] = tracking
            dimensions.width += 2 * tracking
        }
        let image = NSImage(size: dimensions, flipped: false) { _ in
            string.draw(at: .zero, withAttributes: attributes)
            return true
        }
        image.draw(at: NSPoint(x: point.x - dimensions.width / 2, y: point.y - dimensions.height / 2),
                   from: .zero, operation: modernCutoutOperation, fraction: modernCutoutOpacity)
    }

    private static func drawFallbackNormal(level: Int?, externalPower: Bool) {
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

    private static func drawText(_ text: String, centeredAt point: NSPoint, size: CGFloat, operation: NSCompositingOperation, rounded: Bool = true) {
        let baseFont = NSFont.systemFont(ofSize: size, weight: .bold, width: .condensed)
        // Selecting the rounded design resets weight on some macOS releases.
        // Reapply traits so small status-bar digits retain their strong stems.
        let descriptor = rounded ? baseFont.fontDescriptor.withDesign(.rounded)?.withSymbolicTraits([.bold, .condensed]) : nil
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
