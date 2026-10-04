import XCTest

/// Native flow assertions + attached screenshots, reusable on 375/430 pt simulators.
/// No pixel geometry expectations; store tests own the persisted invariants.
@MainActor final class CaptureAttentionUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func launch(_ seed: String, appearance: Int = 1, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PaceInMemory", "YES", "-PaceSeed", seed,
            "-PaceFixedNow", "2026-09-28T12:00:00+08:00", "-PaceTimeZone", "Asia/Kuala_Lumpur",
            "-pace.appearance", String(appearance), "-AppleLanguages", "(en)"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for direction in [true, false] {
            for _ in 0..<8 {
                if element.isHittable { return }
                // A presented List can coexist with Home's background ScrollView.
                // Target the attention list explicitly; otherwise use a hittable
                // scroll container so gestures reach the current presentation.
                let attentionList = self.element(app, "needs-you-list")
                let scroll = app.navigationBars["Needs you"].exists && attentionList.exists
                    ? attentionList
                    : app.scrollViews.allElementsBoundByIndex.last(where: { $0.isHittable })
                        ?? app.collectionViews.allElementsBoundByIndex.last(where: { $0.isHittable })
                if let scroll {
                    let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: direction ? 0.65 : 0.3))
                    let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: direction ? 0.3 : 0.65))
                    start.press(forDuration: 0.05, thenDragTo: end)
                }
            }
        }
        XCTAssertTrue(element.isHittable)
    }

    private func openAttention(_ app: XCUIApplication) {
        let attention = element(app, "capture-attention")
        reveal(attention, in: app)
        attention.tap()
    }

    private func drafts(_ app: XCUIApplication) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pending-draft-"))
    }

    private func screenshot(_ app: XCUIApplication, _ name: String) {
        // isHittable can mean only the first line is visible. Position the
        // attention/long-name fixture before attaching it, especially at AX5.
        // These are scroll actions, not pixel geometry acceptance assertions.
        let focus: XCUIElement?
        if name.hasPrefix("home-") {
            focus = element(app, "capture-attention")
        } else if name.hasPrefix("needs-you-long-") {
            focus = drafts(app).matching(NSPredicate(format: "label CONTAINS %@", "Restoran Nasi Kandar")).firstMatch
        } else { focus = nil }
        if let focus {
            let window = app.windows.firstMatch.frame
            for _ in 0..<4 {
                let frame = focus.frame
                if frame.maxY < window.maxY - window.height * 0.22 || frame.minY < window.minY + window.height * 0.25 { break }
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)))
            }
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testZeroPendingHasNoAttentionOnHomeOrHistory() {
        let app = launch("demo")
        XCTAssertFalse(element(app, "capture-attention").exists)
        app.tabBars.buttons["History"].tap()
        XCTAssertFalse(element(app, "capture-attention").exists)
    }

    func testOneDraftOpensDirectlyDiscardsAndUndoRestores() {
        let app = launch("attention-one")
        openAttention(app)
        XCTAssertTrue(app.navigationBars["Review capture"].waitForExistence(timeout: 5))
        let discard = element(app, "discard-capture-draft")
        reveal(discard, in: app)
        discard.tap()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "capture-attention").exists)
        let undo = element(app, "toast-undo")
        XCTAssertTrue(undo.waitForExistence(timeout: 3))
        undo.tap()
        openAttention(app)
        XCTAssertTrue(app.navigationBars["Review capture"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Restoran Nasi Kandar")).firstMatch.exists)
    }

    func testHistoryOpensManyDraftsAndSwipeUndoStaysInList() {
        let app = launch("attention-many")
        app.tabBars.buttons["History"].tap()
        let attention = element(app, "capture-attention")
        XCTAssertTrue(attention.waitForExistence(timeout: 5))
        XCTAssertEqual(attention.label, "5 captures need you")
        attention.tap()
        XCTAssertTrue(app.navigationBars["Needs you"].waitForExistence(timeout: 5))
        XCTAssertEqual(drafts(app).count, 5)
        let row = drafts(app).firstMatch
        let id = row.identifier
        row.swipeLeft()
        app.buttons["Discard"].tap()
        XCTAssertEqual(drafts(app).count, 4)
        element(app, "toast-undo").tap()
        XCTAssertTrue(element(app, id).waitForExistence(timeout: 5))
        XCTAssertEqual(drafts(app).count, 5)
        XCTAssertTrue(app.navigationBars["Needs you"].exists)
    }

    func testConfirmFromListReturnsToRemainingWork() {
        let app = launch("attention-many")
        openAttention(app)
        let row = drafts(app).matching(NSPredicate(format: "label CONTAINS %@", "Restoran Nasi Kandar")).firstMatch
        reveal(row, in: app)
        row.tap()
        let choice = app.buttons["category-Food & Drink"]
        reveal(choice, in: app)
        choice.tap()
        let confirm = app.buttons["confirm-capture-draft"]
        reveal(confirm, in: app)
        XCTAssertTrue(confirm.isEnabled)
        confirm.tap()
        XCTAssertTrue(app.navigationBars["Needs you"].waitForExistence(timeout: 5))
        XCTAssertEqual(drafts(app).count, 4)
    }

    func testSavedPendingCategoryOpensCategoryAndOtherResolvesIt() {
        let app = launch("attention-category")
        openAttention(app)
        let pending = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pending-category-")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 5))
        pending.tap()
        XCTAssertTrue(app.navigationBars["Category"].waitForExistence(timeout: 5))
        let other = app.buttons["Other"]
        reveal(other, in: app)
        other.tap()
        app.buttons["edit-save"].tap()
        XCTAssertTrue(app.staticTexts["All caught up"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertFalse(element(app, "capture-attention").exists)
    }

    func testWorstCaseScreenshotMatrix() {
        for appearance in [1, 2] {
            for large in [false, true] {
                let app = launch("worst", appearance: appearance, large: large)
                let suffix = "\(Int(app.windows.firstMatch.frame.width))pt-\(appearance == 1 ? "light" : "dark")-\(large ? "AX5" : "default")"
                let attention = element(app, "capture-attention")
                reveal(attention, in: app)
                XCTAssertEqual(attention.label, "5 captures need you · 1 needs a category")
                screenshot(app, "home-attention-\(suffix)")
                attention.tap()
                XCTAssertTrue(app.navigationBars["Needs you"].waitForExistence(timeout: 5))
                screenshot(app, "needs-you-\(suffix)")
                let long = drafts(app).matching(NSPredicate(format: "label CONTAINS %@", "Restoran Nasi Kandar")).firstMatch
                reveal(long, in: app)
                screenshot(app, "needs-you-long-merchant-\(suffix)")
                let missing = drafts(app).matching(NSPredicate(format: "label CONTAINS %@", "Amount not known")).firstMatch
                reveal(missing, in: app)
                missing.tap()
                XCTAssertTrue(app.navigationBars["Review capture"].waitForExistence(timeout: 5))
                let discard = element(app, "discard-capture-draft")
                reveal(discard, in: app)
                screenshot(app, "review-discard-missing-amount-\(suffix)")
                for term in ["percentile", "threshold", "resolver", "M1", "G1", "G2", "G3", "unresolved", "screenshot_generic"] {
                    XCTAssertEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", term)).count, 0)
                }
                app.terminate()
            }
        }
    }

    func testSingleDraftScreenshots() {
        for appearance in [1, 2] {
            let large = appearance == 2
            let app = launch("attention-one", appearance: appearance, large: large)
            let suffix = "\(Int(app.windows.firstMatch.frame.width))pt-\(appearance == 1 ? "light-default" : "dark-AX5")"
            let attention = element(app, "capture-attention")
            reveal(attention, in: app)
            XCTAssertEqual(attention.label, "1 capture needs you")
            screenshot(app, "home-one-\(suffix)")
            attention.tap()
            XCTAssertTrue(app.navigationBars["Review capture"].waitForExistence(timeout: 5))
            reveal(element(app, "discard-capture-draft"), in: app)
            screenshot(app, "review-one-discard-\(suffix)")
            app.terminate()
        }
    }
}
