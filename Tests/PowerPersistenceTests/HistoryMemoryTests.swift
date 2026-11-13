// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2026 RaNDoM6913

import XCTest
import Foundation
import Darwin
@testable import PowerCore
@testable import PowerPersistence

/// Reading months of history at launch must not leave hundreds of megabytes of decoded temporaries in the heap.
/// (Build 70 measured 655 MB footprint / 1.0 GB peak after a launch that summarised ~11 000 stored samples: the
/// per-sample Foundation object tree and its autoreleased copies piled up inside one synchronous loop.)
@MainActor final class HistoryMemoryTests: XCTestCase {
    private func footprintMB() -> Int {
        var info = rusage_info_current()
        withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { _ = proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) }
        }
        return Int(info.ri_phys_footprint >> 20)
    }
    private func snapshot(at date: Date, uptime: TimeInterval, charge: Double) -> BatterySnapshot {
        let ids = ["011", "013", "015", "023", "024", "025", "026", "027", "029", "030", "031", "035", "036", "038", "039", "041", "042",
                   "043", "044", "050", "054", "055", "056", "103", "104", "105", "106", "107", "108", "109", "110", "111", "112", "113", "115"]
        let fields = ids.map { id in
            CatalogReading(definition: BatteryCatalog.definition(id), value: .decimal(charge + Double(id.hashValue % 7)), source: "fixture",
                           keyPath: "fixture/\(id)", collectedAt: date, provenance: .measured, freshness: .fresh,
                           reason: "A long-ish explanation that makes every stored reading realistically heavy for the decoder, as real catalog entries are.")
        }
        return BatterySnapshot(chargePercent: .init(value: Int(charge), source: "fixture", collectedAt: date),
            isCharging: .init(value: true, source: "fixture", collectedAt: date), isExternalPower: .init(value: true, source: "fixture", collectedAt: date),
            collectedAt: date, catalog: fields, monotonicTime: uptime, batteryIdentityToken: "memory-fixture")
    }

    func testReadingALongHistoryAtLaunchKeepsTheHeapSmall() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.sqlite")
        let start = Date().addingTimeInterval(-3 * 86400)
        do {
            let writer = try BatteryHistoryStore(url: url)
            for index in 0..<4000 {
                try writer.record(snapshot(at: start.addingTimeInterval(Double(index) * 60), uptime: Double(index) * 60, charge: 50 + Double(index % 40)))
            }
            try writer.close()
        }
        let store = try BatteryHistoryStore(url: url)
        let before = footprintMB()
        let week = try store.samples(since: Date().addingTimeInterval(-7 * 86400), readingsSince: Date().addingTimeInterval(-3 * 3600))
        let summary = try store.summary()
        _ = try store.catalogReadings(at: Date(), summaryMaxAge: 600)
        let grown = footprintMB() - before
        XCTAssertEqual(week.count, 4000)
        XCTAssertEqual(summary.sampleCount, 4000)
        XCTAssertLessThan(grown, 90, "Loading and summarising 4000 stored samples grew the process by \(grown) MB.")
        XCTAssertEqual(week.first?.readings.count, 0, "Old samples keep scalars only.")
    }
}
