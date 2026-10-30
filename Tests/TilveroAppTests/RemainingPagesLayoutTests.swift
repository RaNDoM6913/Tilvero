import XCTest
import AppKit
import SwiftUI
@testable import TilveroApp

@MainActor final class RemainingPagesLayoutTests: XCTestCase {
    func testRemainingDestinationsRenderWithoutApplyingControls() async throws {
        let saved = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(saved, forName: UserDefaults.argumentDomain) }
        let suite = "TilveroRemainingPages-\(UUID())"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = TilveroModel(isDemo: true, preferences: preferences)
        defer { model.stop() }
        await model.refresh()
        let composition = model.overviewPreferences
        let charge = model.control?.charge
        let sections = InfoSection.allCases.filter { $0 != .overview }
        for language in ["ru", "en"] {
            UserDefaults.standard.setVolatileDomain(saved.merging(["language": language]) { _, value in value }, forName: UserDefaults.argumentDomain)
            model.language = language
            for width: CGFloat in [760, 1000] {
                for section in sections {
                    model.selectedSection = section
                    let host = NSHostingController(rootView: BatteryInfoView(model: model)
                        .environment(\.colorScheme, .light))
                    let window = NSWindow(contentViewController: host)
                    window.appearance = NSAppearance(named: .aqua)
                    window.setContentSize(NSSize(width: width, height: 740))
                    host.view.layoutSubtreeIfNeeded()
                    XCTAssertEqual(host.view.bounds.width, width, accuracy: 1)
                    XCTAssertTrue(host.view.fittingSize.height.isFinite, section.rawValue)
                    if let root = ProcessInfo.processInfo.environment["TILVERO_REMAINING_RENDER_ROOT"] {
                        let folder = URL(fileURLWithPath: root, isDirectory: true)
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                        let bitmap = try XCTUnwrap(host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds))
                        host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
                        let name = "\(section.rawValue)-\(language)-\(Int(width)).png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: folder.appendingPathComponent(name))
                    }
                    window.orderOut(nil)
                }
            }
        }
        XCTAssertEqual(model.overviewPreferences, composition)
        XCTAssertEqual(model.control?.charge, charge)
        XCTAssertNil(model.nativeCharge.observed)
        XCTAssertNil(model.modeReport)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
    }
}
