import XCTest

@MainActor
final class WhoopUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDashboardExposesCoreMetricsAndCompactConnectionStatus() {
        let app = configuredApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Sleep"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Sleep"].firstMatch.exists)
        XCTAssertTrue(app.otherElements["summary.rings"].exists)
        for metric in ["sleep", "recovery", "strain"] {
            XCTAssertTrue(app.descendants(matching: .any)["summary.\(metric)"].exists)
        }
        XCTAssertTrue(app.staticTexts["Sleep duration"].exists)
        XCTAssertTrue(app.staticTexts["Steps"].firstMatch.exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Recovery"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["RHR"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["HRV"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["card.hrv"].exists)
        for metric in ["rhr", "sleep", "recovery", "strain"] {
            XCTAssertTrue(app.descendants(matching: .any)["card.\(metric)"].exists)
        }

        let batteries = app.otherElements["whoop.batteries"]
        XCTAssertTrue(batteries.exists)
        XCTAssertEqual(
            batteries.label,
            "WHOOP connected, battery 73 percent, charging; PowerPack battery 58 percent"
        )
    }

    func testDisconnectedDashboardStillDisplaysBatteryReadings() {
        let app = configuredApplication()
        app.launchEnvironment["WHOOP_MOCK_CONNECTED"] = "0"
        app.launchEnvironment["WHOOP_MOCK_CHARGING"] = "0"
        app.launch()

        let batteries = app.otherElements["whoop.batteries"]
        XCTAssertTrue(batteries.waitForExistence(timeout: 5))
        XCTAssertEqual(
            batteries.label,
            "WHOOP disconnected, battery 73 percent; PowerPack battery 58 percent"
        )
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

    func testSleepingDashboardShowsEmDashesUntilAutomaticProcessing() {
        let app = configuredApplication()
        app.launchEnvironment["WHOOP_MOCK_SLEEPING"] = "1"
        app.launch()

        XCTAssertTrue(app.staticTexts["Sleep"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Sleep, —"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Recovery, —"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Strain, —"].exists)
        XCTAssertFalse(app.buttons["Process"].exists)
    }

    func testDashboardUsesCardsWithoutRangeControlsOrEstimateLabels() {
        let app = configuredApplication()
        app.launch()

        XCTAssertTrue(app.staticTexts["Sleep"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Your trends"].exists)
        XCTAssertFalse(app.staticTexts["Strain estimate"].exists)
        XCTAssertTrue(app.staticTexts["Steps"].exists)
        XCTAssertFalse(app.staticTexts["Step Count"].exists)
        app.swipeUp()
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Strain"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Strain estimate"].exists)
        XCTAssertFalse(app.buttons["Open"].exists)
        XCTAssertFalse(app.staticTexts["Trends"].exists)
        XCTAssertFalse(app.segmentedControls["Trend range"].exists)
        XCTAssertFalse(app.buttons["Week"].exists)
        XCTAssertFalse(app.buttons["Month"].exists)
        XCTAssertFalse(app.buttons["Year"].exists)
    }

    func testHeaderDateOpensHistoryAndMetricTrend() {
        let app = configuredApplication()
        app.launchEnvironment["WHOOP_DEMO_DATA"] = "1"
        app.launch()
        let open = app.buttons["header.date"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.tap()
        let date = app.buttons["history.date"]
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        let latest = date.label
        XCTAssertFalse(app.buttons["history.next"].isEnabled)
        app.buttons["history.previous"].tap()
        XCTAssertNotEqual(date.label, latest)
        XCTAssertTrue(app.buttons["history.next"].isEnabled)
        app.buttons["history.metric.sleep"].tap()
        let week = app.buttons["7D"]
        XCTAssertTrue(week.waitForExistence(timeout: 5), app.debugDescription)
        week.tap()
        XCTAssertTrue(app.descendants(matching: .any)["history.detail.value"].exists)
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'history.row.'")).firstMatch.exists)
    }

    func testStrainStartsAndStopsAnActivity() {
        let app = configuredApplication()
        app.launchEnvironment["WHOOP_DEMO_DATA"] = "1"
        app.launch()
        let strain = app.buttons["card.strain"]
        XCTAssertTrue(strain.waitForExistence(timeout: 5))
        strain.tap()
        let running = app.buttons["log.choice.running"]
        XCTAssertTrue(running.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["log.choice.pickleball"].exists)
        running.tap()
        let start = app.buttons["log.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let end = app.buttons["log.end"]
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        end.tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertTrue(app.buttons["card.strain"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["log.live"].exists)
    }

    private func configuredApplication() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["WHOOP_MOCK_CONNECTED"] = "1"
        app.launchEnvironment["WHOOP_MOCK_BATTERY"] = "73"
        app.launchEnvironment["WHOOP_MOCK_CHARGING"] = "1"
        app.launchEnvironment["WHOOP_MOCK_POWER_PACK_BATTERY"] = "58"
        return app
    }
}
