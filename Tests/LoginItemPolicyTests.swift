import XCTest
@testable import TMEjectGuardCore

/// The launch-at-login repair decides from two booleans, and every one of the
/// four combinations plus "never asked" has to land on the right action.
final class LoginItemPolicyTests: XCTestCase {
    func testNoRecordAdoptsWhatTheSystemSays() {
        XCTAssertEqual(LoginItemPolicy.action(storedIntent: nil, systemEnabled: true),
                       .adoptSystemState(enabled: true))
        XCTAssertEqual(LoginItemPolicy.action(storedIntent: nil, systemEnabled: false),
                       .adoptSystemState(enabled: false))
    }

    func testAgreementNeedsNothing() {
        XCTAssertEqual(LoginItemPolicy.action(storedIntent: true, systemEnabled: true), .nothingToDo)
        XCTAssertEqual(LoginItemPolicy.action(storedIntent: false, systemEnabled: false), .nothingToDo)
    }

    func testADroppedRegistrationIsRepaired() {
        // The case this exists for: the user asked for it, the system lost it.
        XCTAssertEqual(LoginItemPolicy.action(storedIntent: true, systemEnabled: false), .register)
    }

    func testARegistrationAgainstTheSettingIsRemoved() {
        XCTAssertEqual(LoginItemPolicy.action(storedIntent: false, systemEnabled: true), .unregister)
    }
}
