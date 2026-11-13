// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
@testable import TilveroApp

final class CapsuleFillScaleTests: XCTestCase {
    private let scale = CapsuleFillScale(minimum: 40)
    private let total: CGFloat = 250

    func testZeroHasNoFillAndFullFillsTheWholeCapsule() {
        XCTAssertEqual(scale.width(for: 0, in: total), 0)
        XCTAssertEqual(scale.width(for: 1, in: total), total, accuracy: 0.001)
    }

    func testEveryFivePercentStepHasADistinctWidthOverTheWholeRange() {
        let widths = (0...20).map { scale.width(for: Double($0) / 20, in: total) }
        for (a, b) in zip(widths, widths.dropFirst()) { XCTAssertGreaterThan(b, a + 5, "Neighbouring steps differ visibly: \(a) vs \(b)") }
        XCTAssertGreaterThan(scale.width(for: 0.05, in: total), 40, "5 % is wider than the bare icon blob.")
        let picked = [0, 0.05, 0.10, 0.15, 0.25, 0.50, 1].map { scale.width(for: $0, in: total) }
        XCTAssertEqual(Set(picked.map { ($0 * 10).rounded() }).count, picked.count)
    }

    func testValueIsClampedOutsideZeroToOne() {
        XCTAssertEqual(scale.width(for: -0.3, in: total), 0)
        XCTAssertEqual(scale.width(for: 1.7, in: total), total, accuracy: 0.001)
    }

    func testDragInverseRoundTripsEveryStep() {
        for i in 0...20 {
            let v = Double(i) / 20
            let x = scale.width(for: v, in: total)
            XCTAssertEqual(scale.value(atX: x, in: total), v, accuracy: 1e-9, "step \(i)")
        }
    }

    func testDragRoundsToTheNearestStepAndClamps() {
        XCTAssertEqual(scale.value(atX: -20, in: total), 0)
        XCTAssertEqual(scale.value(atX: 10, in: total), 0, "Inside the icon blob means 0 %.")
        XCTAssertEqual(scale.value(atX: 400, in: total), 1)
        let edge = scale.width(for: 0.30, in: total)
        XCTAssertEqual(scale.value(atX: edge + 3, in: total), 0.30, accuracy: 1e-9)
        XCTAssertEqual(scale.value(atX: edge - 3, in: total), 0.30, accuracy: 1e-9)
    }

    func testNarrowCapsuleDegradesWithoutNegativeOrOverflowingWidths() {
        XCTAssertEqual(scale.width(for: 0.5, in: 30), 30, accuracy: 0.001)
        XCTAssertEqual(scale.value(atX: 10, in: 30), 0)
        XCTAssertEqual(scale.value(atX: 10, in: 0), 0)
    }
}
