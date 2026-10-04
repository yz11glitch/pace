import XCTest

@MainActor
final class DataResetUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PaceInMemory", "YES", "-PaceSeed", "demo",
                               "-PaceFixedNow", "2026-09-26T10:00:00+08:00",
                               "-PaceTimeZone", "Asia/Kuala_Lumpur"]
        app.launch()
        return app
    }

    private func button(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let result = app.buttons[id]
        for _ in 0..<5 { app.swipeUp() }
        XCTAssertTrue(result.isHittable)
        return result
    }

    func testBothDestructiveActionsRequireConfirmationAndCancelPreservesData() {
        let app = launch()
        let spent = app.descendants(matching: .any).matching(identifier: "home-spent").firstMatch
        XCTAssertTrue(spent.waitForExistence(timeout: 5))
        let original = spent.label
        app.tabBars.buttons["You"].tap()

        button("reset-pace-data", in: app).tap()
        XCTAssertTrue(app.staticTexts["Reset Pace Data?"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        button("clear-capture-feedback", in: app).tap()
        XCTAssertTrue(app.staticTexts["Clear Capture Feedback?"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        app.tabBars.buttons["Home"].tap()
        XCTAssertEqual(spent.label, original)
    }

    func testResetClearsLedgerAndClearFeedbackLeavesLedgerUsable() {
        let app = launch()
        let spent = app.descendants(matching: .any).matching(identifier: "home-spent").firstMatch
        XCTAssertTrue(spent.waitForExistence(timeout: 5))
        let original = spent.label
        app.tabBars.buttons["You"].tap()
        button("clear-capture-feedback", in: app).tap()
        app.buttons["Clear Feedback"].tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertEqual(spent.label, original)
        app.tabBars.buttons["You"].tap()
        button("reset-pace-data", in: app).tap()
        app.buttons["Reset Data"].tap()
        app.tabBars.buttons["Home"].tap()
        XCTAssertEqual(spent.label, "0 ringgit")
        XCTAssertTrue(app.buttons["add-button"].exists)
    }
}
