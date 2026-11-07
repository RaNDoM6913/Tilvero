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

    func testSpreadLabelsKeepsNeighboursApartInsideTheHeight() {
        let placed = MetricChartView.spreadLabels([60, 62, 118], minGap: 14, height: 120)
        XCTAssertGreaterThanOrEqual(placed[1] - placed[0], 14)
        XCTAssertGreaterThanOrEqual(placed[2] - placed[1], 14)
        XCTAssertLessThanOrEqual(placed[2], 120)
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
