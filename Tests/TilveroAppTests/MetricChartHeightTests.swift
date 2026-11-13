// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import SwiftUI
import AppKit
@testable import TilveroApp

/// The unit row above the plot is gone (the unit sits in the card header); the plot grew by exactly that height, so
/// a chart - and the card around it - keeps the height it had before (owner rule: cards do not change size).
@MainActor final class MetricChartHeightTests: XCTestCase {
    private func height(_ density: MetricChartView.Density) -> CGFloat {
        let now = Date(), window = now.addingTimeInterval(-3600)...now
        let points = stride(from: 0.0, through: 3600.0, by: 60).map {
            HistoryChartPoint(id: UUID(), date: window.lowerBound.addingTimeInterval($0), value: 5 + 3 * sin($0 / 300), series: "x")
        }
        let series = MetricChartSeries.make(points: points, window: window, now: now)
        let view = MetricChartView(specs: [MetricChartSeriesSpec(id: "x", series: series, color: .orange, endLabel: nil)],
                                   scale: MetricChartScale.scale(forMetric: "038", values: series.points.map(\.value)),
                                   window: window, unit: "W", density: density, emptyMessage: "")
        return NSHostingController(rootView: view.frame(width: 300)).sizeThatFits(in: NSSize(width: 300, height: 2000)).height
    }

    func testChartHeightsAreUnchangedByTheTallerPlot() {
        // Recorded from the build with the unit row (build 68).
        XCTAssertEqual(height(.full), 152, accuracy: 0.5)
        XCTAssertEqual(height(.moderate), 112, accuracy: 0.5)
        XCTAssertEqual(height(.compact), 102, accuracy: 0.5)
        XCTAssertEqual(height(.strip), 72, accuracy: 0.5)
    }

    func testThePlotIsTallerThanItWas() {
        XCTAssertEqual(MetricChartView.plotGain, 10)
        XCTAssertGreaterThan(MetricChartView.plotGain, 0)
    }
}
