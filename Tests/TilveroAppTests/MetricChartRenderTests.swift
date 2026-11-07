// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import AppKit
import SwiftUI
import XCTest
@testable import TilveroApp

@MainActor final class MetricChartRenderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var window: ClosedRange<Date> { start...start.addingTimeInterval(3600) }
    private var now: Date { start.addingTimeInterval(3600) }
    private let scale = MetricChartScale(ticks: [-15, -10, -5, 0])

    private func point(_ minute: Double, _ value: Double, series: String = "a") -> HistoryChartPoint {
        HistoryChartPoint(id: UUID(), date: start.addingTimeInterval(minute * 60), value: value, series: series)
    }

    private func spec(_ id: String, _ points: [HistoryChartPoint], now: Date? = nil, label: String? = nil) -> MetricChartSeriesSpec {
        MetricChartSeriesSpec(id: id, series: .make(points: points, window: window, now: now ?? self.now), color: .orange, endLabel: label)
    }

    private var dataSpec: MetricChartSeriesSpec { spec("p", (0...12).map { point(Double($0) * 5, -10 + Double($0 % 3)) }) }
    private var emptySpec: MetricChartSeriesSpec { spec("e", []) }
    private var staleSpec: MetricChartSeriesSpec { spec("s", (0...8).map { point(Double($0) * 5, -8) }, now: now.addingTimeInterval(600)) }
    private var gapSpec: MetricChartSeriesSpec {
        spec("g", (0...4).map { point(Double($0) * 5, -9) } + (8...12).map { point(Double($0) * 5, -7, series: "b") })
    }

    // MARK: Layout

    func testLayoutBandsAreTicksMinusOneAndThereIsNeverALegend() {
        let layout = MetricChartView.layout(specs: [dataSpec, spec("q", [point(60, -5)], label: "B")], scale: scale, density: .full)
        XCTAssertEqual(layout.bandCount, 3)
        XCTAssertEqual(layout.valueTickCount, 4)
        XCTAssertFalse(layout.hasLegend)
        XCTAssertFalse(layout.isDashedEmpty)
        XCTAssertFalse(layout.staleMuted)
        XCTAssertEqual(layout.hatchedGapCount, 0)
    }

    func testSignFlipLayoutHasOneBandPerTickIntervalAndAnInteriorZeroRule() throws {
        let flip = spec("p", [point(5, -8), point(20, -3), point(35, 2), point(50, 6)])
        let flipScale = try XCTUnwrap(MetricChartScale.scale(forMetric: "038", values: flip.series.points.map(\.value)))
        let layout = MetricChartView.layout(specs: [flip], scale: flipScale, density: .full)
        XCTAssertEqual(layout.bandCount, flipScale.ticks.count - 1)
        XCTAssertEqual(layout.valueTickCount, flipScale.ticks.count)
        XCTAssertFalse(layout.isDashedEmpty)
        let zeroY = MetricChartView.yPosition(0, flipScale.domain, plotHeight: 120)
        XCTAssertGreaterThan(zeroY, 0, "The zero rule is inside the plot, between the two signs.")
        XCTAssertLessThan(zeroY, 120)
        // The zero rule sits exactly on a band edge: the y of the zero tick equals the y of a tick boundary.
        let edges = flipScale.ticks.map { MetricChartView.yPosition($0, flipScale.domain, plotHeight: 120) }
        XCTAssertTrue(edges.contains(zeroY))
    }

    func testLayoutTickCountsFollowDensity() {
        XCTAssertEqual(MetricChartView.layout(specs: [dataSpec], scale: scale, density: .full).timeTickCount, 5)
        XCTAssertEqual(MetricChartView.layout(specs: [dataSpec], scale: scale, density: .compact).timeTickCount, 2)
        let six = MetricChartScale(ticks: [0, 5, 10, 15, 20, 25])
        let compact = MetricChartView.layout(specs: [dataSpec], scale: six, density: .compact)
        XCTAssertEqual(compact.bandCount, 5)
        XCTAssertEqual(compact.valueTickCount, 3, "Compact thins a long scale to three labels.")
        XCTAssertEqual(MetricChartView.layout(specs: [dataSpec], scale: six, density: .full).valueTickCount, 6)
    }

    func testLayoutDashedEmptyWithoutDataOrScale() {
        let empty = MetricChartView.layout(specs: [emptySpec], scale: nil, density: .full)
        XCTAssertTrue(empty.isDashedEmpty)
        XCTAssertEqual([empty.bandCount, empty.valueTickCount, empty.timeTickCount], [0, 0, 0], "No axis for an empty chart.")
        XCTAssertTrue(MetricChartView.layout(specs: [emptySpec], scale: scale, density: .full).isDashedEmpty)
        XCTAssertTrue(MetricChartView.layout(specs: [], scale: scale, density: .full).isDashedEmpty)
    }

    func testLayoutMutesAStaleTailAndCountsDistinctGaps() {
        XCTAssertTrue(MetricChartView.layout(specs: [staleSpec], scale: scale, density: .full).staleMuted)
        XCTAssertEqual(MetricChartView.layout(specs: [gapSpec], scale: scale, density: .full).hatchedGapCount, 1)
        XCTAssertEqual(MetricChartView.layout(specs: [gapSpec, gapSpec], scale: scale, density: .full).hatchedGapCount, 1,
                       "A shared gap is hatched once.")
    }

    func testEmptySeriesDoesNotPushARealEndLabel() {
        // An empty spec (or one without a label) is nil and must not move the real label from y = 10.
        let placed = MetricChartView.placeEndLabels([nil, 10, nil], minGap: 14, height: 120)
        XCTAssertEqual(placed[1], 10)
        XCTAssertNil(placed[0])
        XCTAssertNil(placed[2])
        XCTAssertEqual(MetricChartView.placeEndLabels([60, 62, 118], minGap: 14, height: 120).map { $0! }, [55, 69, 113])
    }

    func testEndLabelsNearTheBottomKeepTheGapAndStayInsidePlot() {
        // Two at the bottom: pushed to 116, then the overflow shifts both up so the last sits at height - gap/2.
        XCTAssertEqual(MetricChartView.placeEndLabels([110, 112], minGap: 12, height: 120).map { $0! }, [102, 114])
        // Three: raw 112/113/118 -> 112/124/136 -> shift 22 -> 90/102/114.
        XCTAssertEqual(MetricChartView.placeEndLabels([112, 113, 118], minGap: 12, height: 120).map { $0! }, [90, 102, 114])
        // Input order does not matter.
        XCTAssertEqual(MetricChartView.placeEndLabels([118, 112, nil], minGap: 12, height: 120), [114, 102, nil])
    }

    func testAccessibilityTextForDataStaleAndEmpty() {
        let data = MetricChartView.accessibilityText(specs: [spec("a", [point(60, -10)], label: "Батарея −10,0")], unit: "Вт")
        XCTAssertEqual(data, "\(L10n.text("Chart")), Вт: Батарея −10,0")
        let stale = MetricChartView.accessibilityText(specs: [spec("s", [point(0, -8)], now: now.addingTimeInterval(600), label: "Батарея −8,0")], unit: "Вт")
        XCTAssertEqual(stale, "\(L10n.text("Chart")), Вт: Батарея −8,0 (\(L10n.text("Stale").lowercased()))")
        let empty = MetricChartView.accessibilityText(specs: [emptySpec], unit: "Вт")
        XCTAssertEqual(empty, "\(L10n.text("Chart")), Вт: \(L10n.text("Chart: no data"))")
        let gap = MetricChartView.accessibilityText(specs: [gapSpec], unit: "Вт")
        XCTAssertEqual(gap, "\(L10n.text("Chart")), Вт: \(L10n.text("No recording"))")
    }

    // MARK: Rendering

    private func render(_ specs: [MetricChartSeriesSpec], scale: MetricChartScale?, density: MetricChartView.Density,
                        scheme: ColorScheme, label: String = "x", file: StaticString = #filePath, line: UInt = #line) throws -> CGSize {
        let view = MetricChartView(specs: specs, scale: scale, window: window, unit: "Вт", density: density)
            .frame(width: 320).padding(8)
            .background(scheme == .dark ? Color.black : Color.white)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage, file: file, line: line)
        let bitmap = NSBitmapImageRep(cgImage: image)
        var colors = Set<UInt32>()
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colors.insert(UInt32(c.redComponent * 255) << 16 | UInt32(c.greenComponent * 255) << 8 | UInt32(c.blueComponent * 255))
            }
        }
        XCTAssertGreaterThan(colors.count, 2, "The bitmap must not be blank.", file: file, line: line)
        XCTAssertEqual(image.width, 336, file: file, line: line)
        if let folder = ProcessInfo.processInfo.environment["TILVERO_LOOK_DIR"], let png = bitmap.representation(using: .png, properties: [:]) {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try png.write(to: URL(fileURLWithPath: folder + "/chart-\(label)-\(density)-\(scheme == .dark ? "dark" : "light").png"))
        }
        return CGSize(width: image.width, height: image.height)
    }

    func testRendersEveryStateInLightAndDark() throws {
        let cases: [(String, [MetricChartSeriesSpec], MetricChartScale?)] = [
            ("data", [dataSpec], scale),
            ("empty", [emptySpec], nil),
            ("stale tail", [staleSpec], scale),
            ("gap", [gapSpec], scale),
            ("single point", [spec("one", [point(30, -9)])], scale),
            ("two series", [dataSpec, spec("two", (0...12).map { point(Double($0) * 5, -4) }, label: "B")], scale),
        ]
        for scheme in [ColorScheme.light, .dark] {
            for (name, specs, scale) in cases {
                let full = try render(specs, scale: scale, density: .full, scheme: scheme, label: name.replacingOccurrences(of: " ", with: "-"))
                XCTAssertGreaterThanOrEqual(full.height, 120 + 16, "\(name) \(scheme): full plot is about 120 pt.")
                let compact = try render(specs, scale: scale, density: .compact, scheme: scheme, label: name.replacingOccurrences(of: " ", with: "-"))
                XCTAssertGreaterThanOrEqual(compact.height, 70 + 16, "\(name) \(scheme): compact plot is about 70 pt.")
                XCTAssertLessThan(compact.height, full.height, "\(name) \(scheme)")
            }
        }
    }
}
