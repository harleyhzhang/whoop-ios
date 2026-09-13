import SQLite3
import XCTest

@testable import Sleep

extension WhoopSleepStateTests {
    func testWeekChartUsesAContinuousShapePreservingCurve() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let day: TimeInterval = 86_400
        let points = [
            MetricPoint(date: start, value: 0),
            MetricPoint(date: start.addingTimeInterval(day), value: 10),
            MetricPoint(date: start.addingTimeInterval(2 * day), value: 30),
        ]

        let values = ChartCurveSampler.resampledValues(from: points, count: 5)

        XCTAssertEqual(values.count, 5)
        XCTAssertEqual(values[0], 0)
        XCTAssertEqual(values[2], 10)
        XCTAssertEqual(values[4], 30)
        XCTAssertEqual(values[1], 4.583_333, accuracy: 0.000_001)
        XCTAssertEqual(values[3], 19.166_667, accuracy: 0.000_001)
        XCTAssertNotEqual(values[1], 5)
    }

    func testChartCurveDoesNotOvershootTurningPoints() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let day: TimeInterval = 86_400
        let points = [
            MetricPoint(date: start, value: 10),
            MetricPoint(date: start.addingTimeInterval(day), value: 30),
            MetricPoint(date: start.addingTimeInterval(2 * day), value: 20),
        ]

        let values = ChartCurveSampler.resampledValues(from: points, count: 49)

        XCTAssertEqual(values.first, 10)
        XCTAssertEqual(values.last, 20)
        XCTAssertTrue(values.allSatisfy { (10...30).contains($0) })
        XCTAssertEqual(values.max(), 30)
    }

    func testChartCurveKeepsRangeMorphTopologyStable() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let day: TimeInterval = 86_400
        let week = (0..<7).map {
            MetricPoint(date: start.addingTimeInterval(Double($0) * day), value: Double($0))
        }
        let year = (0..<53).map {
            MetricPoint(date: start.addingTimeInterval(Double($0 * 7) * day), value: Double($0))
        }

        XCTAssertEqual(ChartCurveSampler.resampledValues(from: week, count: 48).count, 48)
        XCTAssertEqual(ChartCurveSampler.resampledValues(from: year, count: 48).count, 48)
    }

    func testChartMarkerSnapsToExactSmoothedCurveAnchor() throws {
        let curve = [
            MorphingMetricPoint(id: 0, position: 0, value: 40),
            MorphingMetricPoint(id: 1, position: 0.25, value: 60),
            MorphingMetricPoint(id: 2, position: 0.5, value: 45),
            MorphingMetricPoint(id: 3, position: 0.75, value: 80),
            MorphingMetricPoint(id: 4, position: 1, value: 70),
        ]

        let aligned = try XCTUnwrap(
            ChartPointAlignment.nearestCurvePoint(to: 0.68, in: curve)
        )

        XCTAssertEqual(aligned.id, 3)
        XCTAssertEqual(aligned.position, 0.75)
        XCTAssertEqual(aligned.value, 80)
    }

    func testChartMarkerAlignmentPreservesCurveEndpoints() throws {
        let curve = [
            MorphingMetricPoint(id: 0, position: 0, value: 40),
            MorphingMetricPoint(id: 1, position: 0.5, value: 60),
            MorphingMetricPoint(id: 2, position: 1, value: 50),
        ]

        XCTAssertEqual(
            try XCTUnwrap(ChartPointAlignment.nearestCurvePoint(to: 0, in: curve)).id,
            0
        )
        XCTAssertEqual(
            try XCTUnwrap(ChartPointAlignment.nearestCurvePoint(to: 1, in: curve)).id,
            2
        )
    }

    func testLongRangeScrubbingRestoresOpaqueHistory() {
        let opacity = ChartContentOpacity.resolve(
            longRangeStyleProgress: 1,
            isScrubbing: true
        )

        XCTAssertEqual(opacity.line, 1)
        XCTAssertEqual(opacity.area, 0.26)
    }

    func testPassiveLongRangeChartRemainsTranslucent() {
        let opacity = ChartContentOpacity.resolve(
            longRangeStyleProgress: 1,
            isScrubbing: false
        )

        XCTAssertEqual(opacity.line, 0.3, accuracy: 0.000_001)
        XCTAssertEqual(opacity.area, 0.07, accuracy: 0.000_001)
    }

    func testPublishedDashboardMetricsShareOneDayKey() throws {
        let health = dailyHealthRecord(dateKey: "2026-09-08")
        let day = PublishedDashboardDay(
            healthRecords: [health],
            stepRecords: [
                dailyStepRecord(dateKey: health.dateKey, stepCount: 8_432),
                dailyStepRecord(dateKey: "2026-09-09", stepCount: 17),
            ],
            recoveryRecords: [
                DailyRecoveryRecord(dateKey: health.dateKey, score: 82, source: "synthetic"),
                DailyRecoveryRecord(dateKey: "2026-09-09", score: 91, source: "synthetic"),
            ]
        )

        XCTAssertEqual(try XCTUnwrap(day.health).dateKey, health.dateKey)
        XCTAssertEqual(try XCTUnwrap(day.steps).dateKey, health.dateKey)
        XCTAssertEqual(try XCTUnwrap(day.recovery).dateKey, health.dateKey)
    }

    func testPublishedDashboardWaitsForEveryMetricFamily() {
        let health = dailyHealthRecord(dateKey: "2026-09-08")
        let day = PublishedDashboardDay(
            healthRecords: [health],
            stepRecords: [dailyStepRecord(dateKey: health.dateKey, stepCount: 8_432)],
            recoveryRecords: []
        )

        XCTAssertNil(day.health)
        XCTAssertNil(day.steps)
        XCTAssertNil(day.recovery)
    }

    func testDashboardHistoryLoadsEveryMetricFamilyInOneSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else {
            XCTFail("Could not open SQLite fixture")
            return
        }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                INSERT INTO daily_health_metric
                    (date_key, sleep_score, sleep_duration_minutes,
                     hrv_rmssd_milliseconds, resting_heart_rate_bpm,
                     source, source_updated_at, imported_at)
                VALUES ('2026-09-09', 88, 480, 64, 52,
                        'synthetic', '2026-09-09T12:00:00Z', 0);
                INSERT INTO whoop_official_daily_metric
                    (date_key, official_recovery_score, official_steps,
                     source_archive, source_manifest_sha256, imported_at)
                VALUES ('2026-09-09', 81, 5432, 'synthetic', 'synthetic', 0);
                """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let snapshot = try await dashboardSnapshot(store: store)

        XCTAssertEqual(snapshot.healthRecords.map(\.dateKey), ["2026-09-09"])
        XCTAssertEqual(snapshot.stepRecords.map(\.dateKey), ["2026-09-09"])
        XCTAssertEqual(snapshot.recoveryRecords.map(\.dateKey), ["2026-09-09"])
        XCTAssertEqual(snapshot.stepRecords.first?.stepCount, 5_432)
        XCTAssertEqual(snapshot.recoveryRecords.first?.score, 81)
    }

    func testDashboardRepositoryPreservesSyntheticQueryResults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
        store.shutdownForTesting()

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else {
            XCTFail("Could not open SQLite fixture")
            return
        }
        defer { sqlite3_close(database) }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                INSERT INTO daily_health_metric
                    (date_key, sleep_score, sleep_duration_minutes,
                     hrv_rmssd_milliseconds, resting_heart_rate_bpm,
                     source, source_updated_at, imported_at)
                VALUES ('2026-09-10', 87, 471, 63, 51,
                        'synthetic', '2026-09-10T12:00:00Z', 0);
                INSERT INTO whoop_official_daily_metric
                    (date_key, official_recovery_score, official_steps,
                     source_archive, source_manifest_sha256, imported_at)
                VALUES ('2026-09-10', 79, 6543, 'synthetic', 'synthetic', 0);
                """, nil, nil, nil), SQLITE_OK)

        let snapshot = try DashboardRepository().loadSnapshot(database: database)

        XCTAssertEqual(snapshot.healthRecords.count, 1)
        XCTAssertEqual(snapshot.healthRecords.first?.dateKey, "2026-09-10")
        XCTAssertEqual(snapshot.healthRecords.first?.sleepScore, 87)
        XCTAssertEqual(snapshot.healthRecords.first?.sleepDurationMinutes, 471)
        XCTAssertEqual(snapshot.healthRecords.first?.hrvRMSSDMilliseconds, 63)
        XCTAssertEqual(snapshot.healthRecords.first?.restingHeartRateBPM, 51)
        XCTAssertEqual(snapshot.stepRecords.first?.stepCount, 6_543)
        XCTAssertEqual(snapshot.recoveryRecords.first?.score, 79)
    }

    func testSQLiteDatabaseSerializesPersistenceState() {
        let database = SQLiteDatabase()
        let group = DispatchGroup()

        for _ in 0..<200 {
            group.enter()
            database.queue.async {
                database.nextDeliverySequence += 1
                group.leave()
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertFalse(database.isOnQueue)
        XCTAssertEqual(database.queue.sync { database.nextDeliverySequence }, 201)
    }

    func testReconnectPolicyBacksOffAndCapsAtOneMinute() {
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 0), 2)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 1), 4)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 4), 32)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 5), 60)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 100), 60)
    }

    func testBatteryLevelStatusReportsChargingOrExternalPower() {
        XCTAssertEqual(
            WhoopBluetoothPolicy.batteryLevelStatus(Data([0x02, 0x23, 0x00, 68])),
            .charging
        )
        XCTAssertEqual(
            WhoopBluetoothPolicy.batteryLevelStatus(Data([0x02, 0x63, 0x00, 100])),
            .charging
        )
        XCTAssertEqual(
            WhoopBluetoothPolicy.batteryLevelStatus(Data([0x02, 0x41, 0x00, 67])),
            .notCharging
        )
        XCTAssertEqual(
            WhoopBluetoothPolicy.batteryLevelStatus(Data([0x02, 0x01, 0x00])),
            .unknown(rawValue: 1)
        )
    }

    func testBatteryUsesOnlySystemRedAtOrBelowTwentyPercent() {
        XCTAssertFalse(WhoopBatteryPresentation.isLow(level: nil))
        XCTAssertTrue(WhoopBatteryPresentation.isLow(level: 0))
        XCTAssertTrue(WhoopBatteryPresentation.isLow(level: 20))
        XCTAssertFalse(WhoopBatteryPresentation.isLow(level: 21))
        XCTAssertFalse(WhoopBatteryPresentation.isLow(level: 35))
    }

    func testBatteryTrackContrastsWithItsLabelColor() {
        XCTAssertEqual(
            WhoopBatteryPresentation.trackTone(level: 73, isCharging: false),
            .lightBehindBlack
        )
        XCTAssertEqual(
            WhoopBatteryPresentation.trackTone(level: nil, isCharging: false),
            .lightBehindBlack
        )
        XCTAssertEqual(
            WhoopBatteryPresentation.trackTone(level: 20, isCharging: false),
            .darkBehindWhite
        )
        XCTAssertEqual(
            WhoopBatteryPresentation.trackTone(level: 73, isCharging: true),
            .darkBehindWhite
        )
    }

    func testLegacyBatteryPowerStateReportsCharging() {
        XCTAssertEqual(WhoopBluetoothPolicy.legacyBatteryStatus(Data([0x30])), .charging)
        XCTAssertEqual(WhoopBluetoothPolicy.legacyBatteryStatus(Data([0x20])), .notCharging)
        XCTAssertEqual(
            WhoopBluetoothPolicy.legacyBatteryStatus(Data([0x00])),
            .unknown(rawValue: 0)
        )
    }
}
