import AppKit
import XCTest
@testable import TilveroApp

@MainActor private final class ExclusivityDriver: SleepTimerTransport {
    var hasIdleHold = false
    func acquireIdleHold(seconds: Int) throws { hasIdleHold = true }
    func extendIdleHold() throws {}
    func replaceIdleHold(seconds: Int) throws {}
    func releaseIdleHold() throws { hasIdleHold = false }
    func isCurrentConsoleSession() -> Bool { true }
    func requestSleep() throws {}
}

/// Keep Awake, the sleep timer, sleep at charge and keep awake until charge are four ways to hold the Mac awake until
/// some condition: only one may run at a time, in every direction.
@MainActor final class AwakeModeExclusivityTests: XCTestCase {
    private func makeModel(_ prefs: UserDefaults, root: URL) -> TilveroModel {
        TilveroModel(isDemo: false, preferences: prefs, historyURL: root.appendingPathComponent("History.sqlite"),
                     snapshotProvider: { .unavailable(reason: "fixture") }, keepAwakeTransport: AwakeFixture(),
                     sleepTimerTransport: ExclusivityDriver())
    }
    private func fixture() throws -> (TilveroModel, UserDefaults, () -> Void) {
        let suite = "Exclusive-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        prefs.set(false, forKey: "historyEnabled")
        let model = makeModel(prefs, root: root)
        return (model, prefs, { model.stop(); prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) })
    }
    private func knowCharge(_ model: TilveroModel) async {
        await model.sleepAtCharge.observe(percent: 64, fresh: true, externalPower: false)
        await model.keepAwakeUntilCharge.observe(percent: 64, fresh: true, externalPower: false)
    }

    func testKeepAwakeBlocksBothChargeModes() async throws {
        let (model, _, cleanUp) = try fixture(); defer { cleanUp() }
        await knowCharge(model)
        XCTAssertTrue(model.sleepAtCharge.canArm(target: 20))
        try SleepPillActions.setAwakeEnabled(model, enabled: true, token: nil)
        XCTAssertFalse(model.sleepAtCharge.canArm(target: 20))
        XCTAssertFalse(model.keepAwakeUntilCharge.canArm(target: 20))
        XCTAssertThrowsError(try model.sleepAtCharge.arm(target: 20))
        XCTAssertThrowsError(try model.keepAwakeUntilCharge.arm(target: 20))
        try model.keepAwake.stop()
        XCTAssertTrue(model.sleepAtCharge.canArm(target: 20), "Turning the running mode off frees the others.")
    }

    func testSleepTimerBlocksBothChargeModes() async throws {
        let (model, _, cleanUp) = try fixture(); defer { cleanUp() }
        await knowCharge(model)
        try model.selectSleepTimer(minutes: 15)
        XCTAssertTrue(model.sleepTimer.isActive)
        XCTAssertFalse(model.sleepAtCharge.canArm(target: 20))
        XCTAssertFalse(model.keepAwakeUntilCharge.canArm(target: 20))
        XCTAssertThrowsError(try model.sleepAtCharge.arm(target: 10))
        model.sleepTimer.cancel()
        XCTAssertTrue(model.sleepAtCharge.canArm(target: 20))
    }

    func testAChargeModeBlocksKeepAwakeTheTimerAndTheOtherChargeMode() async throws {
        for useSleepAtCharge in [true, false] {
            let (model, _, cleanUp) = try fixture(); defer { cleanUp() }
            await knowCharge(model)
            let armed = useSleepAtCharge ? model.sleepAtCharge : model.keepAwakeUntilCharge
            let other = useSleepAtCharge ? model.keepAwakeUntilCharge : model.sleepAtCharge
            try armed.arm(target: 20)
            XCTAssertFalse(other.canArm(target: 10), "Only one charge mode.")
            XCTAssertThrowsError(try other.arm(target: 10))
            XCTAssertFalse(SleepPillActions.canChooseAwake(model))
            XCTAssertFalse(SleepPillActions.canChooseTimer(model))
            XCTAssertFalse(model.canSelectSleepTimerDuration)
            XCTAssertFalse(model.canStartKeepAwakeDraft)
            XCTAssertThrowsError(try model.selectSleepTimer(minutes: 15))
            XCTAssertThrowsError(try model.startKeepAwakeDraft())
            XCTAssertThrowsError(try SleepPillActions.setAwakeEnabled(model, enabled: true, token: nil))
            XCTAssertFalse(model.keepAwake.hasOwnedAssertion)
            XCTAssertFalse(model.sleepTimer.isActive)
            XCTAssertEqual(model.awakeModeBlocker(for: .keepAwake), (useSleepAtCharge ? TilveroModel.AwakeMode.sleepAtCharge : .keepAwakeUntilCharge).title)
            armed.disarm()
            XCTAssertNil(model.awakeModeBlocker(for: .keepAwake))
            XCTAssertTrue(other.canArm(target: 10))
        }
    }

    func testChangingTheLevelOfTheRunningChargeModeIsNotANewMode() async throws {
        let (model, _, cleanUp) = try fixture(); defer { cleanUp() }
        await knowCharge(model)
        try model.sleepAtCharge.arm(target: 30)
        XCTAssertNoThrow(try model.sleepAtCharge.arm(target: 10))
        XCTAssertEqual(model.sleepAtCharge.target, 10)
    }

    func testKeepAwakeAndTheTimerKeepTheirOwnReplaceFlow() async throws {
        let (model, _, cleanUp) = try fixture(); defer { cleanUp() }
        try SleepPillActions.setAwakeEnabled(model, enabled: true, token: nil)
        XCTAssertThrowsError(try model.selectSleepTimer(minutes: 15), "Without the explicit replace nothing starts beside Keep Awake.")
        XCTAssertFalse(model.sleepTimer.isActive)
        try model.selectSleepTimer(minutes: 15, replacingAwake: true)
        XCTAssertTrue(model.sleepTimer.isActive)
        XCTAssertFalse(model.keepAwake.hasOwnedAssertion, "Replacing ends the other mode: never both.")
    }

    func testAwakeIndicatorColorIsPersistedAndUsedByTheIcon() throws {
        let suite = "AwakeColor-\(UUID())", prefs = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { prefs.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        prefs.set(false, forKey: "historyEnabled")
        let first = makeModel(prefs, root: root)
        XCTAssertEqual(first.awakeIndicatorColor, .blue, "Blue by default.")
        first.awakeIndicatorColor = .green
        first.stop()
        let second = makeModel(prefs, root: root)
        defer { second.stop() }
        XCTAssertEqual(second.awakeIndicatorColor, .green)

        let icon = NativeBatteryStatusImage.make(level: 64, style: .inside, externalPower: false, awake: .active, appearance: .macOS27,
                                                 redWhenLow: true, awakeColor: AwakeIndicatorColor.green.nsColor)
        let scale = 4
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(icon.size.width) * scale, pixelsHigh: Int(icon.size.height) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = icon.size
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSColor.black.setFill(); NSRect(origin: .zero, size: icon.size).fill()
            icon.draw(in: NSRect(origin: .zero, size: icon.size)); NSGraphicsContext.restoreGraphicsState()
        }
        var green = 0, blue = 0
        for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
            if c.greenComponent > 0.6 && c.redComponent < 0.4 && c.blueComponent < 0.5 { green += 1 }
            if c.blueComponent > 0.8 && c.redComponent < 0.35 && c.greenComponent < 0.7 { blue += 1 }
        } }
        XCTAssertGreaterThan(green, 40)
        XCTAssertEqual(blue, 0)
    }
}
