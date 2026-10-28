import XCTest
@testable import TilveroApp

final class AppInstancePolicyTests: XCTestCase {
    func testOnlySameResolvedBundleCanReopenSilently() {
        let canonical = URL(fileURLWithPath: "/tmp/Tilvero.app")
        XCTAssertEqual(AppInstancePolicy.action(current: canonical, existing: canonical), .reopen)
        XCTAssertEqual(AppInstancePolicy.action(current: canonical, existing: URL(fileURLWithPath: "/tmp/rejected/Tilvero.app")), .requireSwitch)
        XCTAssertEqual(AppInstancePolicy.action(current: canonical, existing: nil), .requireSwitch)
    }
}
