// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import CoreGraphics
import Foundation

/// Every first-run animation is a pure function of the scene time `t` (seconds), so a frame can be rendered,
/// tested or jumped to, and an interruption simply picks another `t`. Reduce Motion returns the explanatory frame.
enum FirstRunMotion {
    // MARK: Easing

    static func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
    /// Progress of `t` through the interval `a...b`.
    static func segment(_ t: Double, _ a: Double, _ b: Double) -> Double { clamp01((t - a) / (b - a)) }
    static func easeInOutCubic(_ x: Double) -> Double { let t = clamp01(x); return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2 }
    static func easeOutCubic(_ x: Double) -> Double { 1 - pow(1 - clamp01(x), 3) }
    /// Damped spring from 0 to 1 (no overshoot past ~2 % at the default damping).
    static func spring(_ t: Double, response: Double = 0.4, damping z: Double = 0.85) -> Double {
        if t <= 0 { return 0 }
        let w = 2 * Double.pi / response, wd = w * (1 - z * z).squareRoot()
        return 1 - exp(-z * w * t) * (cos(wd * t) + (z * w / wd) * sin(wd * t))
    }
    static func bezier(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * a.x + 2 * u * t * c.x + t * t * b.x, y: u * u * a.y + 2 * u * t * c.y + t * t * b.y)
    }

    // MARK: Looping scenes

    /// A scene of `period` seconds plays at most `loops` times, then rests on `freezeAt` (the explanatory frame).
    struct Loop: Equatable {
        var period: Double, loops: Int, freezeAt: Double
        var totalDuration: Double { period * Double(loops) }
        func time(_ t: Double, reduceMotion: Bool, jumpedToEnd: Bool) -> Double {
            reduceMotion || jumpedToEnd || t >= totalDuration ? freezeAt : max(0, t).truncatingRemainder(dividingBy: period)
        }
        /// After the last loop nothing moves, so the timeline can stop.
        func isFrozen(_ t: Double, reduceMotion: Bool, jumpedToEnd: Bool) -> Bool { reduceMotion || jumpedToEnd || t >= totalDuration }
    }
    static let whereLoop = Loop(period: 3.2, loops: 3, freezeAt: 2.2)
    static let hiddenLoop = Loop(period: 2.8, loops: 3, freezeAt: 2.0)

    /// Drawn scene "where the icon is", in a 480 × 230 canvas.
    struct WhereFrame: Equatable {
        var barIn: Double, cursor: CGPoint, cursorOpacity: Double, press: Double, ripple: Double, highlight: Double, popover: Double, fade: Double
    }
    static let whereCanvas = CGSize(width: 480, height: 230)
    static let whereIconCenter = CGPoint(x: 344, y: 15)

    static func whereScene(_ sceneT: Double, reduceMotion: Bool, jumpedToEnd: Bool = false) -> WhereFrame {
        let t = whereLoop.time(sceneT, reduceMotion: reduceMotion, jumpedToEnd: jumpedToEnd)
        let fade = 1 - segment(t, 2.8, 3.2)
        let icon = whereIconCenter
        let start = CGPoint(x: 220, y: 165), end = CGPoint(x: icon.x + 3, y: icon.y + 5)
        let control = CGPoint(x: (start.x + end.x) / 2 - 36, y: (start.y + end.y) / 2 - 26)
        if reduceMotion {
            // Static cursor on the icon with a single ripple; the drawn popover is open.
            return WhereFrame(barIn: 1, cursor: end, cursorOpacity: 1, press: 0, ripple: 0.45, highlight: 1, popover: 1, fade: 1)
        }
        return WhereFrame(barIn: easeOutCubic(segment(t, 0, 0.4)),
                          cursor: bezier(start, control, end, easeInOutCubic(segment(t, 0.4, 1.1))),
                          cursorOpacity: segment(t, 0.35, 0.5) * fade,
                          press: segment(t, 1.1, 1.18) - segment(t, 1.18, 1.27),
                          ripple: segment(t, 1.1, 1.55),
                          highlight: segment(t, 1.1, 1.25) * fade,
                          popover: clamp01(spring(t - 1.3, response: 0.35, damping: 0.85)) * fade,
                          fade: fade)
    }

    /// Drawn scene "icon hidden behind the notch": hold ⌘ and drag neighbouring icons away.
    struct HiddenFrame: Equatable {
        var notch: Double, cursor: CGPoint, cursorOpacity: Double, drag: Double, iconX: Double, keyDown: Double
    }
    static func hiddenScene(_ sceneT: Double, reduceMotion: Bool, jumpedToEnd: Bool = false) -> HiddenFrame {
        let t = hiddenLoop.time(sceneT, reduceMotion: reduceMotion, jumpedToEnd: jumpedToEnd)
        let neighbour = CGPoint(x: 392, y: 15), destination = CGPoint(x: 150, y: 70), start = CGPoint(x: 90, y: 160)
        if reduceMotion {
            return HiddenFrame(notch: 1, cursor: destination, cursorOpacity: 1, drag: 1, iconX: 330, keyDown: 1)
        }
        let fade = 1 - segment(t, 2.4, 2.8)
        let drag = easeInOutCubic(segment(t, 0.9, 1.6))
        let toNeighbour = easeInOutCubic(segment(t, 0.55, 0.95))
        let tip = CGPoint(x: neighbour.x + 3, y: neighbour.y + 5)
        let cursor = t < 0.95 ? bezier(start, CGPoint(x: 220, y: 90), tip, toNeighbour)
            : CGPoint(x: tip.x + (destination.x - neighbour.x) * drag, y: tip.y + (destination.y - neighbour.y) * drag)
        return HiddenFrame(notch: easeOutCubic(segment(t, 0, 0.3)), cursor: cursor, cursorOpacity: segment(t, 0.5, 0.6) * fade,
                           drag: drag, iconX: 250 + 80 * easeInOutCubic(segment(t, 1.2, 1.8)),
                           keyDown: segment(t, 0.75, 0.85) * (1 - segment(t, 1.9, 2.0)))
    }

    // MARK: Icon fill and the window hand-off

    static let iconFillDuration = 0.7
    /// Fraction of the real level drawn at `t` of the first-launch fill (Reduce Motion: filled at once).
    static func iconFill(_ t: Double, reduceMotion: Bool) -> Double { reduceMotion ? 1 : easeOutCubic(t / iconFillDuration) }
    static func iconFillLevel(_ t: Double, level: Int, reduceMotion: Bool) -> Int {
        Int((Double(level) * iconFill(t, reduceMotion: reduceMotion)).rounded())
    }
    /// The window flies into the icon in 0.35 s; with Reduce Motion it only fades (≤ 0.2 s).
    static func handOffDuration(reduceMotion: Bool) -> Double { reduceMotion ? 0.2 : 0.35 }
    static func crossfadeDuration(reduceMotion: Bool) -> Double { reduceMotion ? 0.15 : 0.24 }

    // MARK: Card pieces

    static let confirmPreviewDuration = 1.2
    struct TouchFrame: Equatable { var dialog: Double, key: Double, finger: Double, glow: Double, rings: Double, collapse: Double }
    static func touchPreview(_ t: Double, reduceMotion: Bool) -> TouchFrame {
        if reduceMotion { return TouchFrame(dialog: 1, key: 1, finger: 0, glow: 1, rings: 1, collapse: 0) }
        return TouchFrame(dialog: clamp01(spring(t, response: 0.3, damping: 0.85)), key: easeOutCubic(segment(t, 0.3, 0.55)),
                          finger: easeOutCubic(segment(t, 0.45, 0.8)), glow: segment(t, 0.7, 0.95),
                          rings: easeOutCubic(segment(t, 0.55, 1.0)), collapse: easeInOutCubic(segment(t, 0.95, 1.2)))
    }

    /// Success checks draw in one after another.
    static func check(_ index: Int, _ t: Double, reduceMotion: Bool) -> Double {
        reduceMotion ? 1 : segment(t, 0.25 + 0.07 * Double(index), 0.47 + 0.07 * Double(index))
    }

    struct CursorFrame: Equatable { var point: CGPoint, opacity: Double, press: Double, ripple: Double }
    /// Guide cursor from `start` to `end` with one click, played once. Reduce Motion: static at `end`, one ripple.
    static func guide(_ t: Double, from start: CGPoint, to end: CGPoint, delay: Double = 0, reduceMotion: Bool) -> CursorFrame {
        let t = t - delay
        let control = CGPoint(x: (start.x + end.x) / 2 - 30, y: (start.y + end.y) / 2 + 10)
        if reduceMotion {
            return CursorFrame(point: end, opacity: segment(t, 0, 0.15) * (1 - segment(t, 1.9, 2.1)), press: 0, ripple: segment(t, 0.2, 0.65))
        }
        return CursorFrame(point: bezier(start, control, end, easeInOutCubic(segment(t, 0.3, 0.9))),
                           opacity: segment(t, 0.2, 0.35) * (1 - segment(t, 1.9, 2.3)),
                           press: segment(t, 0.9, 0.97) - segment(t, 0.97, 1.05), ripple: segment(t, 0.9, 1.35))
    }
    static let guideDuration = 2.3

    // MARK: Beacon and bubble

    struct BeaconFrame: Equatable { var bob: Double, ring: Double }
    static let beaconMotionDuration = 3.6
    static func beacon(_ t: Double, reduceMotion: Bool) -> BeaconFrame {
        guard !reduceMotion, t < beaconMotionDuration else { return BeaconFrame(bob: 0, ring: 0) }
        return BeaconFrame(bob: sin(t * 2 * .pi / 1.2), ring: t.truncatingRemainder(dividingBy: 1.2) / 1.2)
    }

    static let bubbleDuration = 1.8
    struct BubbleFrame: Equatable { var opacity: Double, rings: [Double] }
    static func bubble(_ t: Double, reduceMotion: Bool) -> BubbleFrame {
        let opacity = segment(t, 0, 0.15) * (1 - segment(t, bubbleDuration - 0.25, bubbleDuration))
        if reduceMotion { return BubbleFrame(opacity: opacity, rings: [0, 0]) }
        return BubbleFrame(opacity: opacity, rings: (0..<2).map { segment(t, Double($0) * 0.5, Double($0) * 0.5 + 0.9) })
    }
}
