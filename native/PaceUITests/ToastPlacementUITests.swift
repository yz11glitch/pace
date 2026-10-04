import XCTest

@MainActor
final class ToastPlacementUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PaceInMemory", "YES", "-PaceSeed", "demo",
                               "-PaceFixedNow", "2026-09-26T10:00:00+08:00",
                               "-PaceTimeZone", "Asia/Kuala_Lumpur", "-AppleLanguages", "(en)"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func row(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func deleteFromHistory(_ app: XCUIApplication, _ text: String) {
        app.tabBars.buttons["History"].tap()
        let transaction = row(app, text)
        XCTAssertTrue(transaction.waitForExistence(timeout: 5))
        // At 375 pt the last row can be partly behind Capture. Its swipe
        // must start in the list, so reveal the row before swiping it.
        for _ in 0..<5 {
            if transaction.isHittable && transaction.frame.maxY < element(app, "add-button").frame.minY { break }
            app.swipeUp()
        }
        transaction.swipeLeft()
        let delete = app.buttons["Delete"]
        // A full swipe already deletes on compact phones. Waiting for its
        // absent button can consume the banner's five-second Undo window.
        if delete.exists { delete.tap() }
    }

    /// The banner sits in the top half, below the status area, and clear of the
    /// tab bar and the global Capture control.
    private func assertTopPlacement(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let toast = element(app, "toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 5), file: file, line: line)
        let window = app.windows.firstMatch.frame
        let tabBar = app.tabBars.firstMatch.frame
        let capture = element(app, "add-button").frame
        XCTAssertLessThan(toast.frame.maxY, window.midY, file: file, line: line)
        XCTAssertGreaterThan(toast.frame.minY, window.minY + 20, file: file, line: line)
        XCTAssertLessThan(toast.frame.maxY, tabBar.minY, file: file, line: line)
        XCTAssertFalse(toast.frame.intersects(capture), file: file, line: line)
        XCTAssertTrue(app.tabBars.buttons["Home"].isHittable, file: file, line: line)
        XCTAssertTrue(element(app, "add-button").isHittable, file: file, line: line)
    }

    func testDeleteBannerIsAtTopAndUndoRestores() {
        let app = launch()
        deleteFromHistory(app, "Chicken Rice Shop")
        XCTAssertTrue(element(app, "toast-message").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "toast-message").label.hasPrefix("Deleted"))
        assertTopPlacement(app)
        XCTAssertFalse(row(app, "Chicken Rice Shop").exists)
        element(app, "toast-undo").tap()
        XCTAssertTrue(row(app, "Chicken Rice Shop").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "toast-message").label, "Undone")
        XCTAssertFalse(element(app, "toast-undo").exists)
    }

    /// Each tab raises its own banner, so the 5-second timeout cannot race the assertions.
    func testBannerIsAtTopFromHomeHistoryAndYou() {
        let app = launch()
        let recent = row(app, "Shopee")
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        recent.tap()
        let delete = app.buttons["Delete transaction"]
        for _ in 0..<5 where !delete.isHittable { app.swipeUp() }
        delete.tap()
        app.buttons["Delete"].firstMatch.tap()
        assertTopPlacement(app)

        deleteFromHistory(app, "Chicken Rice Shop")
        assertTopPlacement(app)

        // Let the History banner expire so it cannot sit over the scrolled-to control.
        XCTAssertTrue(element(app, "toast").waitForNonExistence(timeout: 9))
        app.tabBars.buttons["You"].tap()
        let clear = app.buttons["clear-capture-feedback"]
        for _ in 0..<5 { app.swipeUp() }
        XCTAssertTrue(clear.isHittable)
        clear.tap()
        XCTAssertTrue(app.staticTexts["Clear Capture Feedback?"].waitForExistence(timeout: 5))
        app.buttons["Clear Feedback"].tap()
        XCTAssertTrue(app.staticTexts["Capture Feedback cleared"].waitForExistence(timeout: 5))
        assertTopPlacement(app)
    }

    func testBannerDismissesBySwipeAndByTimeout() {
        let app = launch()
        deleteFromHistory(app, "Chicken Rice Shop")
        let toast = element(app, "toast")
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        toast.swipeUp()
        XCTAssertTrue(toast.waitForNonExistence(timeout: 3))

        deleteFromHistory(app, "Big Purchase")
        XCTAssertTrue(toast.waitForExistence(timeout: 5))
        XCTAssertTrue(toast.waitForNonExistence(timeout: 9))
    }
}
