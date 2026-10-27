import XCTest
import PowerCore
@testable import ChargeBackends
@testable import FanBackends

final class BackendContractTests: XCTestCase {
    func testRegisteredLimitsDistinguishNoPolicyFromMalformedOutput() throws {
        XCTAssertEqual(try NativeLimitParser.registeredTargets("No battery level limits set"), [])
        XCTAssertEqual(try NativeLimitParser.registeredTargets("chargeSocLimitSoc = 80;\nchargeSocLimitSoc = 80;"), [80])
        XCTAssertThrowsError(try NativeLimitParser.registeredTargets("unrecognized output"))
        XCTAssertThrowsError(try NativeLimitParser.registeredTargets("chargeSocLimitSoc = 180;"))
    }
    func testPmsetPreservesBatteryAndACSettingsAndArgumentsAreBounded() throws {
        let settings = try EnergyModeParser.parse("Battery Power:\n lowpowermode 1\nAC Power:\n lowpowermode 0\n")
        XCTAssertEqual(settings[.battery], .low)
        XCTAssertEqual(settings[.adapter], .automatic)
        XCTAssertEqual(try EnergyModeBackend.arguments(source: .battery, mode: .low), ["-b", "lowpowermode", "1"])
        XCTAssertThrowsError(try EnergyModeBackend.arguments(source: .adapter, mode: .high))
    }
    func testSMCDecodeRejectsMismatchedLengthAndInvalidTemperature() throws {
        XCTAssertEqual(try SMCValueDecoder.number(type: "fpe2", bytes: [0x1f, 0x40]), 2000)
        XCTAssertThrowsError(try SMCValueDecoder.number(type: "fpe2", bytes: [1]))
        XCTAssertThrowsError(try SMCValueDecoder.number(type: "unknown", bytes: [0, 0]))
        XCTAssertEqual(try SMCValueDecoder.number(type: "sp78", bytes: [0xff, 0x80]), -0.5)
    }
}
