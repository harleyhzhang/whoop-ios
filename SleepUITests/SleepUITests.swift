import XCTest

@MainActor
final class SleepUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDashboardExposesCoreMetricsAndCompactConnectionStatus() {
        let app = configuredApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Sleep"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sleep"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Sleep duration"].exists)
        XCTAssertTrue(app.staticTexts["Steps"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Recovery"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["RHR"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["HRV"].firstMatch.exists)

        let connection = app.otherElements["whoop.connection.status"]
        XCTAssertTrue(connection.exists)
        XCTAssertEqual(connection.label, "WHOOP connected, battery 73 percent, charging")
        XCTAssertFalse(app.buttons["whoop.connection.details"].exists)
        XCTAssertFalse(app.staticTexts["WHOOP 5.0"].exists)
    }

    func testDashboardHasNoManualSleepProcessingControls() {
        let app = configuredApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Sleep"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Sleep detected"].exists)
        XCTAssertFalse(app.buttons["Process"].exists)
        XCTAssertFalse(app.staticTexts["Processing sleep…"].exists)
        XCTAssertFalse(app.staticTexts["Finishing sleep…"].exists)
    }

    func testDashboardUsesOnlyAllHistoryCharts() {
        let app = configuredApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Sleep"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Trends"].exists)
        XCTAssertFalse(app.segmentedControls["Trend range"].exists)
        XCTAssertFalse(app.buttons["Week"].exists)
        XCTAssertFalse(app.buttons["Month"].exists)
        XCTAssertFalse(app.buttons["Year"].exists)
    }

    private func configuredApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["WHOOP_MOCK_CONNECTED"] = "1"
        app.launchEnvironment["WHOOP_MOCK_BATTERY"] = "73"
        app.launchEnvironment["WHOOP_MOCK_CHARGING"] = "1"
        return app
    }
}
