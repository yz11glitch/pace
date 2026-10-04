import XCTest

@MainActor final class DailyDriverUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    private func launch(_ seed: String = "demo", dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PaceInMemory", "YES", "-PaceSeed", seed,
            "-PaceFixedNow", "2026-09-28T12:00:00+08:00", "-PaceTimeZone", "Asia/Kuala_Lumpur",
            "-pace.appearance", dark ? "2" : "1", "-AppleLanguages", "(en)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch(); return app
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        for direction in [true, false] {
            for _ in 0..<8 {
                if element.isHittable { return }
                let scroll = app.descendants(matching: .any).matching(NSPredicate(
                    format: "elementType == %d OR elementType == %d",
                    XCUIElement.ElementType.scrollView.rawValue, XCUIElement.ElementType.collectionView.rawValue
                )).allElementsBoundByIndex.last
                if let scroll {
                    // The List extends behind Capture/tab chrome. Start inside
                    // its visible content instead of the default 80% swipe point.
                    let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: direction ? 0.6 : 0.15))
                    let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: direction ? 0.15 : 0.6))
                    start.press(forDuration: 0.05, thenDragTo: end)
                }
            }
        }
        XCTAssertTrue(element.isHittable)
    }
    private func openAttention(_ app: XCUIApplication) { let item = element(app, "capture-attention"); reveal(item, app); item.tap() }
    private func row(_ app: XCUIApplication, _ name: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func assertSafeCopy(_ app: XCUIApplication) {
        for term in ["percentile", "threshold", "unresolved", "resolver", "Merchant Memory", "OCR", "confidence"] {
            XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", term)).count, 0)
        }
    }

    func testHomeHierarchyAndRecentLimit() {
        let app = launch("worst")
        XCTAssertTrue(element(app, "home-spent").exists)
        XCTAssertTrue(app.staticTexts["Spent this cycle"].exists)
        XCTAssertTrue(element(app, "capture-attention").exists)
        for text in ["Good morning", "Good afternoon", "Good evening", "committed", "to spend", "day so far"] {
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists)
        }
        // Recent is an independent three-row query, unaffected by History.
        XCTAssertLessThanOrEqual(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "ringgit")).count, 3)
        attach(app, "home-frozen")
    }

    func testEditCleanDirtyAndConsequenceOff() {
        let app = launch()
        app.tabBars.buttons["History"].tap()
        row(app, "Chicken Rice Shop").tap()
        XCTAssertFalse(element(app, "edit-save").exists)
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Category")).firstMatch.tap()
        element(app, "category-Groceries").tap()
        let checkbox = element(app, "remember-consequence")
        XCTAssertTrue(checkbox.exists); XCTAssertEqual(checkbox.value as? String, "On")
        checkbox.tap(); XCTAssertEqual(checkbox.value as? String, "Off")
        XCTAssertTrue(element(app, "edit-save").isEnabled)
        attach(app, "edit-category-consequence-off")
        element(app, "edit-save").tap()
        row(app, "Chicken Rice Shop").tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Groceries")).firstMatch.exists)
        XCTAssertFalse(element(app, "edit-save").exists)
    }

    func testOrdinaryAmountEditHasNoConsequence() {
        let app = launch(); app.tabBars.buttons["History"].tap(); row(app, "Chicken Rice Shop").tap()
        element(app, "edit-amount-row").tap()
        app.buttons["Clear"].tap(); element(app, "key-5").tap(); app.buttons["Done"].tap()
        XCTAssertTrue(element(app, "edit-save").exists)
        XCTAssertFalse(element(app, "remember-consequence").exists)
        app.buttons["Close"].tap(); app.buttons["Keep editing"].tap()
        XCTAssertTrue(element(app, "edit-save").exists)
        let bar = app.navigationBars["Edit transaction"]
        bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
            .press(forDuration: 0.05, thenDragTo: bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 5)))
        XCTAssertTrue(app.buttons["Keep editing"].waitForExistence(timeout: 5))
        app.buttons["Keep editing"].tap()
        XCTAssertTrue(element(app, "edit-save").exists)
    }

    func testAllTimeSearchIgnoresVisibleCycleAndFilter() {
        let app = launch(); app.tabBars.buttons["History"].tap()
        app.segmentedControls.buttons["Earned"].tap()
        element(app, "history-search-button").tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap(); search.typeText("Grab")
        XCTAssertTrue(row(app, "Grab").waitForExistence(timeout: 5)) // 24 Sep: previous cycle
        XCTAssertFalse(element(app, "history-period").exists)
        XCTAssertFalse(element(app, "history-filter").exists)
        attach(app, "history-all-time-search-keyboard")
        assertSafeCopy(app)
    }

    func testMissingMerchantSavesAndUndoReturnsDraft() {
        let app = launch("review-missing-merchant"); openAttention(app)
        let save = element(app, "save-without-merchant"); reveal(save, app); save.tap()
        XCTAssertTrue(element(app, "toast-undo").waitForExistence(timeout: 3))
        XCTAssertFalse(element(app, "capture-attention").exists)
        XCTAssertTrue(row(app, "Apple Pay payment").exists)
        element(app, "toast-undo").tap(); openAttention(app)
        XCTAssertTrue(element(app, "save-without-merchant").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "discard-capture-draft").exists)
    }

    func testReviewReportKeepsNoteAcrossCloseThenSaveAndEdit() {
        let app = launch("review-check"); openAttention(app)
        element(app, "review-more").tap(); app.buttons["Report a capture problem"].tap()
        let note = element(app, "capture-issue-note"); note.tap(); note.typeText("Wrong receipt details")
        attach(app, "review-report-keyboard")
        element(app, "review-close").tap(); openAttention(app)
        XCTAssertTrue(app.staticTexts["Problem reported"].exists)
        XCTAssertEqual(element(app, "capture-issue-note").value as? String, "Wrong receipt details")
        element(app, "confirm-capture-draft").tap()
        let saved = row(app, "Review Shop"); XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        XCTAssertFalse(element(app, "edit-save").exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Problem reported")).firstMatch.exists)
        element(app, "edit-more").tap(); app.buttons["Edit problem report"].tap()
        XCTAssertEqual(element(app, "capture-issue-note").value as? String, "Wrong receipt details")
        app.buttons["Remove report"].tap()
        XCTAssertFalse(element(app, "edit-save").exists)
    }

    func testReportedDraftDiscardAndUndoRetainsReport() {
        let app = launch("review-check"); openAttention(app)
        element(app, "review-more").tap(); app.buttons["Report a capture problem"].tap()
        element(app, "discard-capture-draft").tap(); element(app, "toast-undo").tap(); openAttention(app)
        XCTAssertTrue(app.staticTexts["Problem reported"].exists)
        assertSafeCopy(app)
    }

    func testDuplicateThenMissingMerchantNeverStuck() {
        let app = launch("attention-many"); openAttention(app)
        let duplicate = row(app, "Possible duplicate"); reveal(duplicate, app); duplicate.tap()
        XCTAssertTrue(app.buttons["Keep anyway"].exists)
        XCTAssertTrue(element(app, "discard-capture-draft").exists)
        attach(app, "review-duplicate-comparison")
        app.buttons["Keep anyway"].tap()
        let noMerchant = element(app, "save-without-merchant"); reveal(noMerchant, app); noMerchant.tap()
        XCTAssertTrue(app.navigationBars["Needs you"].waitForExistence(timeout: 5))
        assertSafeCopy(app)
    }

    func testMainDecisionStates() {
        for (seed, text) in [("review-large", "Is RM 99,999.99 right?"), ("review-date", "When was this?"), ("review-failed", "This payment may not have gone through")] {
            let app = launch(seed); openAttention(app)
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.waitForExistence(timeout: 5))
            XCTAssertTrue(element(app, "discard-capture-draft").exists)
            attach(app, seed); assertSafeCopy(app); app.terminate()
        }
    }

    func testConsumerScreenshotMatrix() {
        for dark in [false, true] {
            for large in [false, true] {
                let app = launch("ledger-edge", dark: dark, large: large)
                let suffix = "\(Int(app.windows.firstMatch.frame.width))pt-\(dark ? "dark" : "light")-\(large ? "AX5" : "default")"
                attach(app, "home-\(suffix)")
                app.tabBars.buttons["History"].tap(); attach(app, "history-edge-\(suffix)")
                let long = row(app, "A very long merchant"); reveal(long, app); long.tap()
                attach(app, "edit-large-income-long-merchant-\(suffix)")
                app.buttons["Close"].tap()
                let missing = row(app, "Expense"); reveal(missing, app); missing.tap()
                attach(app, "edit-small-missing-merchant-\(suffix)")
                assertSafeCopy(app); app.terminate()
            }
        }
    }

    func testEmptyAndHundredsOfHistoryRows() {
        let empty = launch("empty"); empty.tabBars.buttons["History"].tap()
        XCTAssertTrue(empty.staticTexts["Nothing yet"].exists); attach(empty, "history-empty"); empty.terminate()
        let app = launch("ledger-scale"); app.tabBars.buttons["History"].tap()
        XCTAssertEqual(element(app, "history-total").label, "625 transactions")
        attach(app, "history-hundreds")
        element(app, "history-search-button").tap(); let search = app.searchFields.firstMatch; search.tap(); search.typeText("Ledger entry")
        XCTAssertTrue(app.buttons["Show all 618"].waitForExistence(timeout: 5))
        app.buttons["Show all 618"].tap(); attach(app, "history-expanded-hundreds")
    }
    func testLargeHistoryScrollAndMerchant() {
        let app = launch("ledger-edge", large: true)
        app.tabBars.buttons["History"].tap()
        let merchant = row(app, "A very long merchant")
        reveal(merchant, app)
        merchant.tap()
        XCTAssertTrue(app.navigationBars["Edit transaction"].waitForExistence(timeout: 5))
        attach(app, "edit-long-merchant-AX5")
    }

    func testAmbiguousAmountHasNoDefaultAndReturnsToRemainingDrafts() {
        let app = launch("attention-many"); openAttention(app)
        let ambiguous = row(app, "Kedai Buku"); reveal(ambiguous, app); ambiguous.tap()
        XCTAssertFalse(element(app, "confirm-capture-draft").isEnabled)
        XCTAssertTrue(app.buttons["RM 12.00"].exists)
        attach(app, "review-ambiguous-no-default")
        app.buttons["RM 12.00"].tap()
        let shopping = element(app, "category-Shopping"); reveal(shopping, app); shopping.tap()
        XCTAssertTrue(element(app, "confirm-capture-draft").isEnabled)
        element(app, "confirm-capture-draft").tap()
        XCTAssertTrue(app.navigationBars["Needs you"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pending-draft-")).count, 4)
    }

    func testMissingAmountUsesKeypadAndKeepsCategoryQuestion() {
        let app = launch("attention-many"); openAttention(app)
        let missing = row(app, "Pasar Malam"); reveal(missing, app); missing.tap()
        XCTAssertFalse(element(app, "confirm-capture-draft").isEnabled)
        element(app, "key-0").tap(); element(app, "key-point").tap(); element(app, "key-5").tap()
        element(app, "confirm-capture-draft").tap()
        let food = element(app, "category-Food & Drink"); reveal(food, app); food.tap()
        XCTAssertTrue(element(app, "remember-consequence").exists)
        attach(app, "review-missing-amount-corrected")
        element(app, "confirm-capture-draft").tap()
        XCTAssertTrue(app.navigationBars["Needs you"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pending-draft-")).count, 4)
    }

    func testAccessibleMerchantAndReportKeyboardActions() {
        let merchant = launch("review-missing-merchant", large: true); openAttention(merchant)
        XCTAssertTrue(merchant.keyboards.firstMatch.waitForExistence(timeout: 5))
        let save = element(merchant, "save-without-merchant")
        XCTAssertTrue(save.isHittable)
        XCTAssertTrue(element(merchant, "discard-capture-draft").isHittable)
        attach(merchant, "review-missing-merchant-keyboard-AX5")
        save.tap(); XCTAssertFalse(element(merchant, "capture-attention").exists); merchant.terminate()
        let report = launch("review-check", large: true); openAttention(report)
        element(report, "review-more").tap(); report.buttons["Report a capture problem"].tap()
        let note = element(report, "capture-issue-note"); reveal(note, report); note.tap(); note.typeText("Please check")
        XCTAssertTrue(element(report, "confirm-capture-draft").isHittable)
        XCTAssertTrue(element(report, "discard-capture-draft").isHittable)
        attach(report, "review-report-keyboard-AX5")
        element(report, "review-close").tap(); openAttention(report)
        XCTAssertEqual(element(report, "capture-issue-note").value as? String, "Please check")
    }

    func testEditReportSurvivesDiscardedTransactionChanges() {
        let app = launch("review-check"); openAttention(app)
        element(app, "confirm-capture-draft").tap()
        row(app, "Review Shop").tap()
        element(app, "edit-amount-row").tap()
        app.buttons["Clear"].tap(); element(app, "key-5").tap(); app.buttons["Done"].tap()
        element(app, "edit-more").tap(); app.buttons["Report a capture problem"].tap()
        let note = element(app, "capture-issue-note"); note.tap(); note.typeText("Noticed after saving")
        element(app, "save-capture-report").tap()
        XCTAssertTrue(element(app, "edit-save").exists)
        app.buttons["Close"].tap(); app.buttons["Discard changes"].tap()
        row(app, "Review Shop").tap()
        XCTAssertFalse(element(app, "edit-save").exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Problem reported")).firstMatch.exists)
        XCTAssertTrue(element(app, "edit-amount-row").label.contains("8 ringgit"))
        element(app, "edit-more").tap(); app.buttons["Edit problem report"].tap()
        XCTAssertEqual(element(app, "capture-issue-note").value as? String, "Noticed after saving")
        attach(app, "edit-independent-report-after-discarded-changes")
    }
}
