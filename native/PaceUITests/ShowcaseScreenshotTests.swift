import XCTest

/// Reproducible portfolio screenshots from in-memory fictional data.
@MainActor final class ShowcaseScreenshotTests: XCTestCase {
    func testShowcaseScreenshots() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-PaceInMemory", "YES", "-PaceSeed", "showcase",
            "-PaceFixedNow", "2026-09-28T12:00:00+08:00", "-PaceTimeZone", "Asia/Kuala_Lumpur",
            "-pace.appearance", "1", "-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 10))
        let left = app.descendants(matching: .any).matching(identifier: "home-left").firstMatch
        XCTAssertTrue(left.label.contains("left of"), "Showcase must remain within its plan")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "salary not received yet")).firstMatch.exists)
        attach("home")
        let attention = app.descendants(matching: .any).matching(identifier: "capture-attention").firstMatch
        XCTAssertTrue(attention.waitForExistence(timeout: 5))
        attention.tap()
        XCTAssertTrue(app.navigationBars["Needs you"].waitForExistence(timeout: 5))
        attach("needs-you")
        let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Kedai Buku Ilmu")).firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        XCTAssertTrue(app.navigationBars["Review capture"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Shopping"].exists)
        attach("review-capture")
        app.buttons["review-close"].tap()
        app.buttons["Done"].tap()
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.navigationBars["History"].waitForExistence(timeout: 5))
        attach("history")
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
