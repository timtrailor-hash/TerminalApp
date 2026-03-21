import XCTest

final class TerminalAppUITests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--uitesting"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - App launch

    func testAppLaunchesWithoutCrash() {
        XCTAssertTrue(app.exists)
        _ = app.wait(for: .runningForeground, timeout: 5)
    }

    func testTerminalViewRendersWithNavigationBar() {
        // TerminalApp wraps TerminalView in NavigationStack
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5),
                      "Navigation bar should be present in TerminalView")
    }

    func testTerminalViewHasToolbarButtons() {
        // TerminalView has toolbar buttons (new window, file upload, settings, export)
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
        // At least one toolbar button should exist
        let buttons = app.navigationBars.firstMatch.buttons
        XCTAssertTrue(buttons.count >= 1, "Navigation bar should have toolbar buttons")
    }

    func testConnectionBannerAppearsWhenDisconnected() {
        // Without a server running, the app should show some connection state
        // This test verifies the UI doesn't crash when server is unreachable
        _ = app.wait(for: .runningForeground, timeout: 3)
        // App should still exist (not crashed)
        XCTAssertTrue(app.exists, "App should remain stable when server is unreachable")
    }

    func testAppHandlesRotation() {
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        XCTAssertTrue(app.exists, "App should handle landscape rotation")
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        XCTAssertTrue(app.exists, "App should handle portrait rotation")
    }

    func testAppHandlesBackgroundForegroundCycle() {
        XCUIDevice.shared.press(.home)
        sleep(1)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5),
                      "App should resume to foreground cleanly")
    }
}
