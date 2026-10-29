import XCTest
@testable import KeyboardBackends

@MainActor final class KeyboardBacklightTests: XCTestCase {
    func testInvalidBrightnessIsRejectedBeforeAnyNativeDispatch() async {
        let transport = NativeKeyboardBacklightTransport()
        for value in [Double.nan, .infinity, -.infinity, -0.1, 1.1] {
            do {
                try await transport.setBrightness(value, keyboardID: 0)
                XCTFail("Invalid brightness reached the native operation")
            } catch { XCTAssertEqual(error as? KeyboardBacklightError, .invalidBrightness) }
        }
    }
    func testDecoderRejectsMalformedNumbersAndNonBooleanStatus() throws {
        let valid: [String: Any] = ["keyboardID": NSNumber(value: UInt64(123)), "brightness": NSNumber(value: 0.375),
                                    "automaticBrightness": true, "suppressed": false, "dimmed": false]
        let observation = try NativeKeyboardBacklightTransport.decode(valid)
        XCTAssertEqual(observation.keyboardID, 123)
        XCTAssertEqual(observation.brightness, 0.375)
        XCTAssertEqual(observation.isEnabled, true)
        for field in valid.keys {
            var broken = valid; broken.removeValue(forKey: field)
            XCTAssertThrowsError(try NativeKeyboardBacklightTransport.decode(broken))
        }
        for invalid: Any in [true, -1, 1.25, "123"] {
            var broken = valid; broken["keyboardID"] = invalid
            XCTAssertThrowsError(try NativeKeyboardBacklightTransport.decode(broken))
        }
        for invalid: Any in [true, Double.nan, Double.infinity, -0.01, 1.01, "0.5"] {
            var broken = valid; broken["brightness"] = invalid
            XCTAssertThrowsError(try NativeKeyboardBacklightTransport.decode(broken))
        }
        for field in ["automaticBrightness", "suppressed", "dimmed"] {
            var broken = valid; broken[field] = NSNumber(value: 1)
            XCTAssertThrowsError(try NativeKeyboardBacklightTransport.decode(broken))
        }
    }
    func testObservationDoesNotTurnSuppressedSettingIntoPhysicalBrightness() throws {
        for suppressed in [false, true] {
            for dimmed in [false, true] {
                let observation = try KeyboardBacklightObservation(keyboardID: 1, brightness: 0.4, automaticBrightness: true,
                                                                  suppressed: suppressed, dimmed: dimmed, observedAt: Date())
                XCTAssertEqual(observation.isEnabled, suppressed || dimmed ? nil : true)
                let off = try KeyboardBacklightObservation(keyboardID: 1, brightness: 0, automaticBrightness: true,
                                                          suppressed: suppressed, dimmed: dimmed, observedAt: Date())
                XCTAssertEqual(off.isEnabled, false)
            }
        }
    }
}
