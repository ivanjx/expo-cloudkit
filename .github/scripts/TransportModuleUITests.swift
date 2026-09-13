import XCTest

/// The Release app embeds the packed SDK's JS. Its opt-in smoke calls the real
/// native create/dispose methods; the label appears only after those succeed.
final class TransportModuleUITests: XCTestCase {
  func testPackedModuleLoadsAndTearsDownWithoutCloudOperations() {
    let app = XCUIApplication()
    app.launch()
    XCTAssertTrue(app.descendants(matching: .any)["transport-native-loaded"].firstMatch.waitForExistence(timeout: 60), app.debugDescription)
  }
}
