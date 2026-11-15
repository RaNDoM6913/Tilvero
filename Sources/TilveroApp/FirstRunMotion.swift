// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import CoreGraphics
import Foundation

/// Every first-run animation is a pure function of time `t` (seconds), so a frame can be rendered, tested or skipped.
/// The one motion that matters is real, not drawn: the setup window flies into the real menu bar icon, the icon fills
/// up and the real quick menu drops from it. That shows where Tilvero lives in about one second. Reduce Motion: the
/// window only fades, the icon is drawn full at once, the menu opens without animation.
enum FirstRunMotion {
    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    /// Progress of `t` through the interval `a...b`.
    static func segment(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
    static func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - clamp01(x), 3) }
    static func easeInOutCubic(_ x: Double) -> Double { let t = clamp01(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    /// Damped spring from 0 to 1 (overshoot of a few percent at this damping).
    static func spring(_ t: Double, response: Double = 0.35, damping z: Double = 0.78) -> Double {
        if t <= 0 { return 0 }
        let w = 2 * Double.pi / response, wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + (z * w / wd) * sin(wd * t))
    }

    // MARK: Window entrance (one timeline, about 1.4 s, then nothing moves)

    /// The window content rises 8 pt and grows from 96 % with a spring while it fades in (~0.35 s).
    struct Entrance: Equatable { var opacity: Double, scale: Double, rise: Double }
    static func entrance(_ t: Double, reduceMotion: Bool) -> Entrance {
        if reduceMotion { return Entrance(opacity: segment(t, 0, 0.15), scale: 1, rise: 0) }
        let p = spring(t, response: 0.42, damping: 0.8)
        return Entrance(opacity: easeOutCubic(segment(t, 0, 0.25)), scale: 0.96 + 0.04 * p, rise: 8 * (1 - p))
    }
    /// The five options appear one after another, 50 ms apart, each in 0.3 s.
    static func rowAppear(_ index: Int, _ t: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : easeOutCubic(segment(t, 0.12 + 0.05 * Double(index), 0.42 + 0.05 * Double(index)))
    }
    /// The hero battery charges up once and its bolt gives one soft pulse, then it rests.
    struct Hero: Equatable { var fill: Double, bolt: Double, glow: Double }
    static func hero(_ t: Double, reduceMotion: Bool) -> Hero {
        if reduceMotion { return Hero(fill: 1, bolt: 1, glow: 0) }
        let bump = segment(t, 0.95, 1.35)
        let pulse = bump > 0 && bump < 1 ? sin(bump * .pi) : 0   // exactly at rest before and after
        return Hero(fill: 0.12 + 0.88 * easeInOutCubic(segment(t, 0.15, 1.0)), bolt: 1 + 0.16 * pulse, glow: pulse)
    }
    static let entranceEnd = 1.4
    static func entranceSettled(_ t: Double, reduceMotion: Bool) -> Bool { reduceMotion || t >= entranceEnd }

    // MARK: Terminal hint (a flat illustration: password dots, then the Return key; at most three loops)

    static let terminalHintPeriod = 2.6
    static let terminalHintLoops = 3
    struct TerminalHint: Equatable { var dots: Int, press: Double, done: Double }
    static func terminalHint(_ t: Double, reduceMotion: Bool) -> TerminalHint {
        let total = terminalHintPeriod * Double(terminalHintLoops)
        if reduceMotion || t >= total { return TerminalHint(dots: 6, press: 0, done: 1) }
        let u = t.truncatingRemainder(dividingBy: terminalHintPeriod)
        let press = segment(u, 1.45, 1.55) - segment(u, 1.6, 1.75)
        return TerminalHint(dots: Int((6 * segment(u, 0.25, 1.25)).rounded(.down)), press: press, done: segment(u, 1.7, 2.0) * (1 - segment(u, 2.4, 2.6)))
    }
    static func terminalHintSettled(_ t: Double, reduceMotion: Bool) -> Bool {
        reduceMotion || t >= terminalHintPeriod * Double(terminalHintLoops)
    }

    /// The green check after a granted permission draws in, then the window leaves (`successBeat`).
    static func check(_ t: Double, reduceMotion: Bool) -> Double { reduceMotion ? 1 : easeOutCubic(segment(t, 0, 0.3)) }
    static func successBeat(reduceMotion: Bool) -> Double { reduceMotion ? 0.25 : 0.6 }

    /// The window flies into the icon in 0.35 s; with Reduce Motion it only fades (≤ 0.2 s).
    static func handOffDuration(reduceMotion: Bool) -> Double { reduceMotion ? 0.2 : 0.35 }
    static func crossfadeDuration(reduceMotion: Bool) -> Double { reduceMotion ? 0.15 : 0.24 }

    /// The menu bar icon fills from 0 to the real level as the window lands (Reduce Motion: full at once).
    static let iconFillDuration = 0.5
    static func iconFill(_ t: Double, reduceMotion: Bool) -> Double { reduceMotion ? 1 : easeOutCubic(t / iconFillDuration) }
    static func iconFillLevel(_ t: Double, level: Int, reduceMotion: Bool) -> Int {
        Int((Double(level) * iconFill(t, reduceMotion: reduceMotion)).rounded())
    }

    /// The "charge limit is here" coach on the real Charge tab: fades in, two soft pulses, rests, fades out.
    static let coachDuration = 4.0
    struct CoachFrame: Equatable { var opacity: Double, pulse: Double }
    static func coach(_ t: Double, reduceMotion: Bool) -> CoachFrame {
        let opacity = segment(t, 0, 0.25) * (1 - segment(t, coachDuration - 0.4, coachDuration))
        guard !reduceMotion else { return CoachFrame(opacity: opacity, pulse: 0) }
        let pulse = t < 2 ? (t.truncatingRemainder(dividingBy: 1)) : 0
        return CoachFrame(opacity: opacity, pulse: pulse)
    }
}

/// Where the first-run window sits: centered on the screen of the menu bar icon, like any setup window.
enum FirstRunWindowGeometry {
    static func centered(size: NSSize, in visible: NSRect) -> NSRect {
        clamp(NSRect(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded(),
                     width: size.width, height: size.height), within: visible)
    }

    /// A new content height keeps the window's center (wherever the user moved it) and stays on screen.
    static func resized(_ frame: NSRect, to size: NSSize, within visible: NSRect) -> NSRect {
        clamp(NSRect(x: (frame.midX - size.width / 2).rounded(), y: (frame.midY - size.height / 2).rounded(),
                     width: size.width, height: size.height), within: visible)
    }

    static func clamp(_ frame: NSRect, within visible: NSRect) -> NSRect {
        var f = frame
        f.origin.x = min(max(f.minX, visible.minX), max(visible.minX, visible.maxX - f.width))
        f.origin.y = min(max(f.minY, visible.minY), max(visible.minY, visible.maxY - f.height))
        return f
    }

    /// The small target the window shrinks into, centered on the icon.
    static func landing(on button: NSRect) -> NSRect {
        NSRect(x: button.midX - 20, y: button.midY - 12, width: 40, height: 24)
    }
}

/// Whether the menu bar icon can be seen. On a Mac with a notch, items that do not fit are placed behind it, outside
/// both auxiliary areas beside the notch.
enum StatusItemVisibility {
    struct Screen: Equatable {
        var frame: NSRect
        var auxiliaryLeft: NSRect?
        var auxiliaryRight: NSRect?
    }

    /// Horizontal positions only: an auto-hidden menu bar can put the item above the screen, which is not "no room".
    /// The auxiliary areas are taken as screen-relative when they do not lie inside the screen's global frame
    /// (a built-in display that is not the main one).
    static func isVisible(button: NSRect?, screens: [Screen], windowVisible: Bool = true) -> Bool {
        guard windowVisible, let button, button.width > 0, button.height > 0 else { return false }
        guard let screen = screens.first(where: { $0.frame.minX <= button.midX && button.midX < $0.frame.maxX }) else { return false }
        guard let left = screen.auxiliaryLeft, let right = screen.auxiliaryRight else { return true }
        func global(_ area: NSRect) -> NSRect {
            screen.frame.minX <= area.minX && area.maxX <= screen.frame.maxX ? area : area.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        }
        return [global(left), global(right)].contains { $0.minX - 1 <= button.minX && button.maxX <= $0.maxX + 1 }
    }
}
