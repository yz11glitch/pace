import XCTest

@MainActor
final class CaptureIssueUITests: XCTestCase {
    func testManualTransactionDoesNotShowCaptureIssueControl() {
        let app = XCUIApplication()
        app.launchArguments = ["-PaceInMemory", "YES", "-PaceSeed", "demo",
            "-PaceFixedNow", "2026-09-26T10:00:00+08:00", "-PaceTimeZone", "Asia/Kuala_Lumpur"]
        app.launch()
        app.tabBars.buttons["History"].tap()
        let transaction = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chicken Rice Shop")).firstMatch
        XCTAssertTrue(transaction.waitForExistence(timeout: 5))
        transaction.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "edit-amount-row")
            .firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "report-capture-issue")
            .firstMatch.exists)
    }
}
