import XCTest

/// Screen tests: the real app on a simulator, started with a few contacts, a chat and some calls (see `UITestSeed`).
/// On an iPad (regular width) the Recents, Contacts, Chats and Keypad tabs are two panes; on an iPhone they are one column that pushes pages.
/// No PBX is needed. Run with tests/ios/run-ui-tests.sh, which runs them on an iPhone and an iPad simulator.
final class ScreenTests: XCTestCase {
    private var app: XCUIApplication!
    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchEnvironment["L1NE_UITEST_SEED"] = "1"
        app.launch()
        XCTAssertTrue(app.buttons["Contacts"].waitForExistence(timeout: 15), "the tab bar never appeared")
    }

    private func tab(_ name: String) { app.buttons[name].firstMatch.tap() }
    private func exists(_ text: String, timeout: TimeInterval = 5) -> Bool { app.staticTexts[text].firstMatch.waitForExistence(timeout: timeout) }
    private func gone(_ text: String) -> Bool { !app.staticTexts[text].firstMatch.exists }
    private func tapRow(_ name: String) { app.staticTexts[name].firstMatch.tap() }
    /// A keypad key: its label reads like "2 ABC", so match on the digit it starts with.
    private func key(_ digit: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", digit)).firstMatch }
    /// The message box of an open chat.
    private var messageBox: XCUIElement { app.textFields["Message"].exists ? app.textFields["Message"] : app.textViews["Message"] }
    private func waitForMessageBox() -> Bool { app.textFields["Message"].waitForExistence(timeout: 5) || app.textViews["Message"].waitForExistence(timeout: 2) }

    // MARK: iPad: two panes

    func testIPadShowsContactsAsTwoPanes() throws {
        try XCTSkipUnless(isPad, "iPad only")
        tab("Contacts")
        XCTAssertTrue(exists("Nobody selected"))
        tapRow("Alice Archer")
        XCTAssertTrue(exists("SIP address")); XCTAssertTrue(gone("Nobody selected"))
        XCTAssertTrue(app.staticTexts["Bob Brandt"].exists, "the list stays beside the card")
    }
    func testIPadShowsChatsAsTwoPanes() throws {
        try XCTSkipUnless(isPad, "iPad only")
        tab("Chats")
        XCTAssertTrue(exists("No chat selected"))
        tapRow("Alice Archer")
        XCTAssertTrue(waitForMessageBox(), "the message box of the open chat")
        XCTAssertGreaterThanOrEqual(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'lunch'")).count, 2, "the list preview and the conversation both show the text")
        XCTAssertTrue(gone("No chat selected"))
    }
    func testIPadShowsRecentCallsBesideTheKeypad() throws {
        try XCTSkipUnless(isPad, "iPad only")
        tab("Keypad")
        XCTAssertTrue(exists("Recent calls"))
        key("2").tap()                                   // 2 = A, B, C: Alice and Bob match
        XCTAssertTrue(exists("Matching contacts")); XCTAssertTrue(gone("Recent calls"))
    }
    func testIPadShowsRecentsAsTwoPanes() throws {
        try XCTSkipUnless(isPad, "iPad only")
        tab("Recents")
        XCTAssertTrue(exists("Nobody selected"))
        tapRow("Alice Archer")
        XCTAssertTrue(exists("SIP address"))
    }
    func testIPadStaysTwoPanesWhenRotated() throws {
        try XCTSkipUnless(isPad, "iPad only")
        tab("Contacts"); tapRow("Alice Archer"); XCTAssertTrue(exists("SIP address"))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(exists("SIP address")); XCTAssertTrue(app.staticTexts["Bob Brandt"].exists)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(exists("SIP address")); XCTAssertTrue(app.staticTexts["Bob Brandt"].exists)
    }

    // MARK: Accounts

    func testSwipingAnAccountAsksFirstAndThenRemovesIt() throws {
        app.buttons["Accounts and settings"].firstMatch.tap()
        app.buttons["Accounts"].firstMatch.tap()
        let row = app.staticTexts["Screen test"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Remove account"].waitForExistence(timeout: 5), "it asks before removing anything")
        XCTAssertTrue(app.staticTexts["Screen test"].exists, "nothing is removed until the question is answered")
        app.buttons["Remove account"].tap()
        let gone = NSPredicate(format: "exists == false")
        XCTAssertEqual(XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: gone, object: app.staticTexts["Screen test"].firstMatch)], timeout: 8), .completed, "the account is gone")
    }

    // MARK: iPhone: one column

    func testIPhoneKeepsContactsAsOneColumnWithAPage() throws {
        try XCTSkipIf(isPad, "iPhone only")
        tab("Contacts")
        XCTAssertTrue(gone("Nobody selected"))
        tapRow("Alice Archer")
        XCTAssertTrue(exists("SIP address")); XCTAssertTrue(app.navigationBars.buttons.firstMatch.exists, "a page with a back button")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Bob Brandt"].waitForExistence(timeout: 5)); XCTAssertTrue(gone("SIP address"))
    }
    func testIPhoneKeepsTheKeypadAlone() throws {
        try XCTSkipIf(isPad, "iPhone only")
        tab("Keypad")
        XCTAssertTrue(gone("Recent calls"))
        key("2").tap()
        XCTAssertTrue(gone("Matching contacts"))
    }
    func testIPhoneOpensAChatInAPage() throws {
        try XCTSkipIf(isPad, "iPhone only")
        tab("Chats"); tapRow("Alice Archer")
        XCTAssertTrue(waitForMessageBox(), "the message box of the open chat")
        XCTAssertTrue(gone("No chat selected"))
    }
    func testStartingAChatWithSomeoneNewOpensIt() throws {                  // the bug where the sheet closed and no chat appeared
        try XCTSkipIf(isPad, "iPhone only")
        tab("Chats")
        app.buttons["New message"].tap()
        XCTAssertTrue(exists("New message") || app.navigationBars["New message"].waitForExistence(timeout: 5))
        tapRow("Bob Brandt")
        XCTAssertTrue(waitForMessageBox(), "a chat with Bob opened")
        XCTAssertGreaterThanOrEqual(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Bob Brandt")).count, 1, "the chat is headed with Bob's name")
    }
}
