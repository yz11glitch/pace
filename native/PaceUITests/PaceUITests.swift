import XCTest

@MainActor
final class PaceUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(seed: String? = nil, region: String = "en_US") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PaceInMemory", "YES", "-PaceFixedNow", "2026-09-26T10:00:00+08:00",
                               "-PaceTimeZone", "Asia/Kuala_Lumpur", "-AppleLanguages", "(en)", "-AppleLocale", region]
        if let seed { app.launchArguments += ["-PaceSeed", seed] }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func enter(_ app: XCUIApplication, digits: [String], type: String? = nil, category: String? = nil) {
        element(app, "add-button").tap()
        for digit in digits { element(app, "key-\(digit)").tap() }
        if let type { app.buttons[type].tap() }
        element(app, "entry-next").tap()
        if let category { element(app, "category-\(category)").tap() }
        element(app, "entry-save").tap()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
    }

    func testHomeHierarchyAndPayCycle() {
        let app = launch(seed: "demo")
        XCTAssertTrue(element(app, "home-spent").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Spent this cycle"].exists)
        XCTAssertTrue(app.staticTexts["Set aside this cycle"].exists)
        XCTAssertTrue(app.staticTexts["Recent"].exists)
        app.tabBars.buttons["History"].tap()
        XCTAssertEqual(element(app, "history-period").label, "This cycle · 25 Sep – 24 Oct")
        app.buttons["Previous cycle"].tap()
        XCTAssertEqual(element(app, "history-period").label, "Last cycle · 25 Aug – 24 Sep")
    }

    func testCaptureSelectThenSaveAndUndo() {
        let app = launch()
        enter(app, digits: ["1", "8"], category: "Food & Drink")
        XCTAssertTrue(app.staticTexts["Food & Drink"].waitForExistence(timeout: 5))
        element(app, "add-button").tap()
        element(app, "key-5").tap()
        element(app, "key-0").tap()
        app.buttons["Set aside"].tap()
        element(app, "entry-next").tap()
        element(app, "entry-save").tap()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5))
        app.buttons["Undo"].tap()
        XCTAssertFalse(app.staticTexts["Set aside"].firstMatch.exists)
    }

    func testEarnedAndRefundRemainDistinct() {
        let app = launch()
        enter(app, digits: ["5", "0"], type: "Earned")
        XCTAssertEqual(element(app, "home-spent").label, "0 ringgit")
        element(app, "add-button").tap()
        element(app, "key-2").tap()
        element(app, "key-0").tap()
        app.buttons["Earned"].tap()
        app.buttons["Refund"].tap()
        element(app, "entry-next").tap()
        element(app, "entry-save").tap()
        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertEqual(element(app, "home-spent").label, "minus 20 ringgit")
        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Refund")).firstMatch.waitForExistence(timeout: 5))
    }

    func testFinancialLocaleIsIndependentOfDeviceRegion() {
        var labels: [String] = []
        for region in ["en_US", "ms_MY", "de_DE"] {
            let app = launch(seed: "demo", region: region)
            let spent = element(app, "home-spent")
            XCTAssertTrue(spent.waitForExistence(timeout: 5))
            labels.append(spent.label)
            app.terminate()
        }
        XCTAssertEqual(Set(labels).count, 1)
    }

    func testNotificationDetailControlUsesNativeSettingsLink() {
        let app = launch()
        app.tabBars.buttons["You"].tap()
        let detail = app.switches["Show transaction details"]
        for _ in 0..<4 where !detail.isHittable { app.swipeUp() }
        XCTAssertTrue(detail.isHittable)
        let initial = detail.value as? String
        let thumb = detail.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        thumb.tap()
        XCTAssertNotEqual(detail.value as? String, initial)
        thumb.tap() // Keep the next UI test's preference unchanged.
        XCTAssertEqual(detail.value as? String, initial)
        let settings = app.buttons["Open Pace notification settings"]
        for _ in 0..<4 where !settings.isHittable { app.swipeUp() }
        XCTAssertTrue(settings.isHittable)
    }

    func testVisionScreenshotFixtureInCaptureLab() {
        let app = launch()
        app.tabBars.buttons["You"].tap()
        let lab = app.buttons["Capture Lab"]
        for _ in 0..<6 where !lab.isHittable { app.swipeUp() }
        XCTAssertTrue(lab.isHittable)
        lab.tap()
        let fixture = app.buttons["Run Vision OCR fixture"]
        for _ in 0..<4 where !fixture.isHittable { app.swipeUp() }
        XCTAssertTrue(fixture.isHittable)
        fixture.tap()
        let result = element(app, "ocr-fixture-result")
        let recognized = NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
                                     "RM 23.90", "ZUS", "blank rejected", "malformed rejected")
        expectation(for: recognized, evaluatedWith: result)
        waitForExpectations(timeout: 30)
    }

    func testCategorizerBenchmarkOpensFromCaptureLab() {
        let app = launch()
        app.tabBars.buttons["You"].tap()
        let lab = app.buttons["Capture Lab"]
        for _ in 0..<6 where !lab.isHittable { app.swipeUp() }
        lab.tap()
        let benchmark = app.buttons["Apple FM categorizer benchmark"]
        for _ in 0..<6 where !benchmark.isHittable { app.swipeUp() }
        XCTAssertTrue(benchmark.isHittable)
        benchmark.tap()
        XCTAssertTrue(element(app, "fm-bench-availability").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "fm-bench-run").exists)
    }

    func testScrollNavigationRestsAndTabsStayIndependent() {
        let app = launch(seed: "demo")
        let home = element(app, "home-cycle")
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        let homeTop = home.frame.minY
        XCTAssertFalse(app.navigationBars.firstMatch.exists, "Home hides its navigation bar")
        let scroll = app.scrollViews.firstMatch
        scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
        XCTAssertEqual(home.frame.minY, homeTop, accuracy: 2, "Home must return to its single resting top position")
        scroll.swipeUp()
        scroll.swipeDown()
        XCTAssertEqual(home.frame.minY, homeTop, accuracy: 2)
        app.tabBars.buttons["History"].tap()
        let historyBar = app.navigationBars["History"]
        XCTAssertTrue(historyBar.waitForExistence(timeout: 5))
        let inlineHeight = historyBar.frame.height
        XCTAssertLessThan(inlineHeight, 70, "History must have an inline title at rest")
        let list = element(app, "history-list")
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.38)))
        XCTAssertEqual(historyBar.frame.height, inlineHeight, accuracy: 2, "A small pull must not create search chrome")
        list.swipeUp()
        list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85)))
        XCTAssertEqual(historyBar.frame.height, inlineHeight, accuracy: 2, "Overscroll must not reveal a large title")
        list.swipeUp()
        XCTAssertEqual(historyBar.frame.height, inlineHeight, accuracy: 2)
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        element(app, "history-search-button").tap()
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "Search should focus when opened")
        searchField.tap()
        searchField.typeText("Shopee")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Shopee")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chicken Rice Shop")).firstMatch.exists)
        XCTAssertFalse(app.buttons["Calendar view"].exists)
        app.buttons["Close"].tap()
        XCTAssertFalse(searchField.exists)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Chicken Rice Shop")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "history-period").exists)
        XCTAssertTrue(element(app, "history-filter").exists)
        app.tabBars.buttons["Home"].tap()
        XCTAssertEqual(home.frame.minY, homeTop, accuracy: 2, "History navigation state must not alter Home")
        XCTAssertTrue(element(app, "add-button").exists, "Capture fallback must remain available above the tab bar")
    }
}
