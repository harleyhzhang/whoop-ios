import SQLite3
import XCTest

@testable import Sleep

final class WhoopSleepStateTests: XCTestCase {
    func testSleepStatePreservesUnknownRawValuesWithoutTreatingThemAsWake() {
        let unknown = SleepState(rawValue: 99)
        XCTAssertEqual(unknown, .unknown(99))
        XCTAssertEqual(unknown.rawValue, 99)
        XCTAssertFalse(unknown.isExplicitlyAwake)
        XCTAssertFalse(
            WhoopAutomaticSleepPolicy.canFinalize(
                latestState: unknown,
                secondsSinceLastAsleep: 60 * 60,
                latestSampleIsCurrent: true
            )
        )
    }

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

    func testPendingWakeKeepsLastPublishedDashboardVisible() {
        let health = dailyHealthRecord(dateKey: "2026-09-08")
        let day = PublishedDashboardDay(
            healthRecords: [health],
            stepRecords: [dailyStepRecord(dateKey: health.dateKey, stepCount: 8_432)],
            recoveryRecords: [
                DailyRecoveryRecord(
                    dateKey: health.dateKey,
                    score: 82,
                    source: "synthetic"
                )
            ]
        )

        XCTAssertEqual(day.health?.dateKey, health.dateKey)
        XCTAssertEqual(day.steps?.dateKey, health.dateKey)
        XCTAssertEqual(day.recovery?.dateKey, health.dateKey)
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
        guard let database else { throw XCTSkip("Could not open SQLite fixture") }
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
        guard let database else { throw XCTSkip("Could not open SQLite fixture") }
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

    func testPhysiologicalDayDoesNotRollAtMidnightBeforeWake() {
        let firstWake = Date(timeIntervalSince1970: 1_000)
        let nextWake = Date(timeIntervalSince1970: 100_000)
        let boundaries = [
            WhoopWakeBoundary(dateKey: DayKey(rawValue: "2026-09-08")!, wokeAt: firstWake),
            WhoopWakeBoundary(dateKey: DayKey(rawValue: "2026-09-09")!, wokeAt: nextWake),
        ]

        XCTAssertEqual(
            WhoopPhysiologicalDay.dateKey(
                for: nextWake.addingTimeInterval(-1),
                publishedWakes: boundaries,
                civilFallback: DayKey(rawValue: "2026-09-09")!
            ),
            DayKey(rawValue: "2026-09-08")!
        )
        XCTAssertEqual(
            WhoopPhysiologicalDay.dateKey(
                for: nextWake,
                publishedWakes: boundaries,
                civilFallback: DayKey(rawValue: "2026-09-09")!
            ),
            DayKey(rawValue: "2026-09-09")!
        )
    }

    func testReconnectPolicyBacksOffAndCapsAtOneMinute() {
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 0), 2)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 1), 4)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 4), 32)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 5), 60)
        XCTAssertEqual(WhoopReconnectPolicy.delaySeconds(forAttempt: 100), 60)
    }

    func testReplayIndexIsLimitedToReplayPronePacketClasses() {
        XCTAssertFalse(WhoopHandshakeProbe.shouldDeduplicateTransportRetries(frameType: nil))
        XCTAssertFalse(
            WhoopHandshakeProbe.shouldDeduplicateTransportRetries(frameType: .realtimeHeartRate)
        )
        XCTAssertTrue(
            WhoopHandshakeProbe.shouldDeduplicateTransportRetries(frameType: .historicalSample)
        )
        XCTAssertTrue(
            WhoopHandshakeProbe.shouldDeduplicateTransportRetries(frameType: .historicalMetadata)
        )
        XCTAssertTrue(
            WhoopHandshakeProbe.shouldDeduplicateTransportRetries(frameType: .transport50)
        )
    }

    func testBatteryLevelStatusReportsChargingOrExternalPower() {
        XCTAssertEqual(
            WhoopHandshakeProbe.batteryLevelStatus(Data([0x02, 0x23, 0x00, 68])),
            .charging
        )
        XCTAssertEqual(
            WhoopHandshakeProbe.batteryLevelStatus(Data([0x02, 0x63, 0x00, 100])),
            .charging
        )
        XCTAssertEqual(
            WhoopHandshakeProbe.batteryLevelStatus(Data([0x02, 0x41, 0x00, 67])),
            .notCharging
        )
        XCTAssertEqual(
            WhoopHandshakeProbe.batteryLevelStatus(Data([0x02, 0x01, 0x00])),
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
        XCTAssertEqual(WhoopHandshakeProbe.legacyBatteryStatus(Data([0x30])), .charging)
        XCTAssertEqual(WhoopHandshakeProbe.legacyBatteryStatus(Data([0x20])), .notCharging)
        XCTAssertEqual(
            WhoopHandshakeProbe.legacyBatteryStatus(Data([0x00])),
            .unknown(rawValue: 0)
        )
    }

    func testFreshWristEventsReportOnAndOffState() {
        let timestamp: UInt32 = 1_800_000_000
        let receivedAt = Date(timeIntervalSince1970: TimeInterval(timestamp + 20))

        XCTAssertEqual(
            WhoopHandshakeProbe.freshWhoop5WristState(
                wristEventFrame(event: 9, timestamp: timestamp),
                receivedAt: receivedAt
            ),
            true
        )
        XCTAssertEqual(
            WhoopHandshakeProbe.freshWhoop5WristState(
                wristEventFrame(event: 10, timestamp: timestamp),
                receivedAt: receivedAt
            ),
            false
        )
    }

    func testStaleOrCorruptWristEventsCannotScheduleWearState() {
        let timestamp: UInt32 = 1_800_000_000
        let event = wristEventFrame(event: 10, timestamp: timestamp)
        XCTAssertNil(
            WhoopHandshakeProbe.freshWhoop5WristState(
                event,
                receivedAt: Date(timeIntervalSince1970: TimeInterval(timestamp + 46))
            )
        )

        var corruptEvent = event
        corruptEvent[10] ^= 0x01
        XCTAssertNil(
            WhoopHandshakeProbe.freshWhoop5WristState(
                corruptEvent,
                receivedAt: Date(timeIntervalSince1970: TimeInterval(timestamp))
            )
        )
    }

    func testInterimUpStateDoesNotSplitOneNight() {
        var firstRun: [WhoopStore.HistoricalRow] = []
        for timestamp in stride(from: 0.0, through: 7 * 60 * 60, by: 20.0) {
            firstRun.append(row(at: timestamp, state: 2))
        }
        var resumedRun: [WhoopStore.HistoricalRow] = []
        let resumedStart = 8.0 * 60 * 60
        let resumedEnd = resumedStart + 15 * 60
        for timestamp in stride(from: resumedStart, through: resumedEnd, by: 20.0) {
            resumedRun.append(row(at: timestamp, state: 2))
        }

        let groups = WhoopStore.groupedAsleepRows(firstRun + resumedRun)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].first?.timestamp, 0)
        XCTAssertEqual(groups[0].last?.timestamp, 8 * 60 * 60 + 15 * 60)
    }

    func testLongGapStartsANewSleep() {
        let rows = [
            row(at: 0, state: 2),
            row(at: 60, state: 2),
            row(at: 2 * 60 * 60, state: 2),
        ]

        XCTAssertEqual(WhoopStore.groupedAsleepRows(rows).count, 2)
    }

    func testUpStateGroupsOneNightButDoesNotAddSleepDuration() {
        let asleep = [
            row(at: 0, state: 2),
            row(at: 60, state: 2),
            row(at: 20 * 60, state: 2),
            row(at: 21 * 60, state: 2),
        ]

        XCTAssertEqual(WhoopStore.groupedAsleepRows(asleep).count, 1)
        XCTAssertEqual(
            WhoopStore.elapsedSeconds(across: asleep, cadence: 60),
            4 * 60,
            accuracy: 0.001
        )
    }

    func testShortUpStateKeepsSleepProvisional() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("sleep.sqlite3"),
            runBackgroundDecoding: false
        )
        defer { store.shutdownForTesting() }
        let peripheral = UUID()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let startedAt = now.addingTimeInterval(-(3 * 60 * 60 + 5 * 60))

        for timestamp in stride(
            from: startedAt.timeIntervalSince1970,
            through: now.addingTimeInterval(-60).timeIntervalSince1970,
            by: 60
        ) {
            _ = try await append(
                version18Frame(timestamp: UInt32(timestamp), sleepState: 2),
                store: store,
                peripheral: peripheral,
                sessionID: nil
            )
        }
        _ = try await append(
            version18Frame(timestamp: UInt32(now.timeIntervalSince1970), sleepState: 3),
            store: store,
            peripheral: peripheral,
            sessionID: nil
        )

        let snapshot = await sleepSnapshot(store: store, now: now)

        XCTAssertTrue(snapshot.isSleeping)
    }

    func testAutomaticSleepPolicyFinalizesUpAfterTenMinutes() {
        XCTAssertTrue(
            WhoopAutomaticSleepPolicy.reportsSleeping(
                latestState: .up,
                secondsSinceLastAsleep: 9 * 60,
                latestSampleIsCurrent: true
            )
        )
        XCTAssertFalse(
            WhoopAutomaticSleepPolicy.canFinalize(
                latestState: .up,
                secondsSinceLastAsleep: 9 * 60,
                latestSampleIsCurrent: true
            )
        )
        XCTAssertFalse(
            WhoopAutomaticSleepPolicy.reportsSleeping(
                latestState: .up,
                secondsSinceLastAsleep: 10 * 60,
                latestSampleIsCurrent: true
            )
        )
        XCTAssertTrue(
            WhoopAutomaticSleepPolicy.canFinalize(
                latestState: .up,
                secondsSinceLastAsleep: 10 * 60,
                latestSampleIsCurrent: true
            )
        )
    }

    func testAutomaticSleepPolicyFinalizesExplicitAwakeWithoutDelay() {
        XCTAssertTrue(
            WhoopAutomaticSleepPolicy.canFinalize(
                latestState: .awakePrimary,
                secondsSinceLastAsleep: 60,
                latestSampleIsCurrent: false
            )
        )
        XCTAssertTrue(
            WhoopAutomaticSleepPolicy.canFinalize(
                latestState: .awakeAlternate,
                secondsSinceLastAsleep: 60,
                latestSampleIsCurrent: true
            )
        )
    }

    func testAutomaticProvisionalWakeSilentlyGrowsWhenSleepResumes() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("sleep.sqlite3"),
            runBackgroundDecoding: false
        )
        defer { store.shutdownForTesting() }
        let peripheral = UUID()
        let firstWakeCheck = Date(timeIntervalSince1970: 1_800_000_000)
        let startedAt = firstWakeCheck.addingTimeInterval(-(4 * 60 * 60 + 10 * 60))
        let firstLastAsleep = firstWakeCheck.addingTimeInterval(-10 * 60)
        let firstSessionID = try await beginOffload(store: store, peripheral: peripheral)

        for timestamp in stride(
            from: startedAt.timeIntervalSince1970,
            through: firstLastAsleep.timeIntervalSince1970,
            by: 60
        ) {
            _ = try await append(
                version18Frame(timestamp: UInt32(timestamp), sleepState: 2),
                store: store,
                peripheral: peripheral,
                sessionID: firstSessionID
            )
        }
        _ = await appendRealtime(
            Data([0x01]),
            heartRate: 55,
            rrIntervals: Array(repeating: [UInt16(900), UInt16(1_000)], count: 11).flatMap { $0 },
            deliveredAt: startedAt.addingTimeInterval(60 * 60),
            store: store,
            peripheral: peripheral
        )
        _ = try await append(
            version18Frame(
                timestamp: UInt32(firstWakeCheck.timeIntervalSince1970),
                sleepState: 3
            ),
            store: store,
            peripheral: peripheral,
            sessionID: firstSessionID
        )
        _ = try await append(
            metadataFrame(type: 3),
            store: store,
            peripheral: peripheral,
            sessionID: firstSessionID
        )

        let provisional = await sleepSnapshot(
            store: store,
            now: firstWakeCheck,
            allowAutomaticFinalization: true
        )
        let provisionalRecord = try XCTUnwrap(provisional.finalizedRecord)

        let resumedAt = firstLastAsleep.addingTimeInterval(40 * 60)
        let resumedUntil = resumedAt.addingTimeInterval(20 * 60)
        let correctedWakeCheck = resumedUntil.addingTimeInterval(10 * 60)
        let correctionSessionID = try await beginOffload(store: store, peripheral: peripheral)
        for timestamp in stride(
            from: resumedAt.timeIntervalSince1970,
            through: resumedUntil.timeIntervalSince1970,
            by: 60
        ) {
            _ = try await append(
                version18Frame(timestamp: UInt32(timestamp), sleepState: 2),
                store: store,
                peripheral: peripheral,
                sessionID: correctionSessionID
            )
        }
        _ = try await append(
            version18Frame(
                timestamp: UInt32(correctedWakeCheck.timeIntervalSince1970),
                sleepState: 3
            ),
            store: store,
            peripheral: peripheral,
            sessionID: correctionSessionID
        )
        _ = try await append(
            metadataFrame(type: 3),
            store: store,
            peripheral: peripheral,
            sessionID: correctionSessionID
        )

        let corrected = await sleepSnapshot(
            store: store,
            now: correctedWakeCheck,
            allowAutomaticFinalization: true
        )
        let correctedRecord = try XCTUnwrap(corrected.finalizedRecord)
        XCTAssertEqual(correctedRecord.dateKey, provisionalRecord.dateKey)
        XCTAssertGreaterThan(
            correctedRecord.sleepDurationMinutes ?? 0,
            provisionalRecord.sleepDurationMinutes ?? 0
        )
        XCTAssertEqual(correctedRecord.sleepEndAt, ISO8601DateFormatter().string(from: resumedUntil))
    }

    func testObservedAsleepRangesExcludeLongUpInterval() {
        let asleep = [
            row(at: 0, state: 2),
            row(at: 60, state: 2),
            row(at: 20 * 60, state: 2),
            row(at: 21 * 60, state: 2),
        ]

        let ranges = WhoopStore.observedAsleepRanges(rows: asleep, cadence: 60)

        XCTAssertEqual(ranges.count, 2)
        XCTAssertFalse(ranges.contains { $0.contains(10 * 60) })
    }

    func testRealtimeRMSSDUsesAdjacentPackets() {
        let packets = [
            WhoopStore.RealtimeRRPacket(timestamp: 1, intervals: [900, 1_000]),
            WhoopStore.RealtimeRRPacket(timestamp: 2, intervals: [900]),
        ]

        let value = WhoopStore.rmssdFromRealtimePackets(
            packets,
            minimumDifferencesPerWindow: 2
        )

        XCTAssertNotNil(value)
        XCTAssertEqual(value ?? 0, 100, accuracy: 0.001)
    }

    func testRealtimeRMSSDBreaksContinuityAcrossDeliveryGap() {
        let packets = [
            WhoopStore.RealtimeRRPacket(timestamp: 1, intervals: [900]),
            WhoopStore.RealtimeRRPacket(timestamp: 10, intervals: [1_000]),
        ]

        XCTAssertNil(
            WhoopStore.rmssdFromRealtimePackets(
                packets,
                minimumDifferencesPerWindow: 1
            ))
    }

    func testRealtimeRMSSDRejectsImplausibleBeatWithoutBridgingIt() {
        let packets = [
            WhoopStore.RealtimeRRPacket(timestamp: 1, intervals: [900, 100, 1_000])
        ]

        XCTAssertNil(
            WhoopStore.rmssdFromRealtimePackets(
                packets,
                minimumDifferencesPerWindow: 1
            ))
    }

    func testRealtimeRMSSDUsesRobustMedianAcrossWindows() {
        let packets = [
            WhoopStore.RealtimeRRPacket(timestamp: 1, intervals: [900, 1_000]),
            WhoopStore.RealtimeRRPacket(timestamp: 301, intervals: [900, 950]),
            WhoopStore.RealtimeRRPacket(timestamp: 601, intervals: [800, 1_000]),
        ]

        let value = WhoopStore.rmssdFromRealtimePackets(
            packets,
            minimumDifferencesPerWindow: 1
        )

        XCTAssertEqual(value ?? 0, 100, accuracy: 0.001)
    }

    func testRealtimeRMSSDPerformanceAcrossEightHourStream() {
        let packets = (0..<(8 * 60 * 60)).map { second in
            WhoopStore.RealtimeRRPacket(
                timestamp: TimeInterval(second),
                intervals: [UInt16(second.isMultiple(of: 2) ? 900 : 1_000)].map(Double.init)
            )
        }
        let options = XCTMeasureOptions()
        options.iterationCount = 3

        measure(metrics: [XCTClockMetric()], options: options) {
            XCTAssertNotNil(WhoopStore.rmssdFromRealtimePackets(packets))
        }
    }

    func testPrimaryMetricsMustArriveTogether() {
        let partial = DailyHealthRecord(
            dateKey: "2026-09-05",
            sleepScore: 82,
            sleepDurationMinutes: 426,
            hrvRMSSDMilliseconds: nil,
            restingHeartRateBPM: nil,
            sleepID: "partial",
            cycleID: nil,
            source: "whoop5_local_v2",
            sourceArchive: nil,
            sourceUpdatedAt: "2026-09-05T13:46:00Z"
        )
        let complete = DailyHealthRecord(
            dateKey: "2026-09-05",
            sleepScore: 96,
            sleepDurationMinutes: 501,
            hrvRMSSDMilliseconds: 62,
            restingHeartRateBPM: 49,
            sleepID: "complete",
            cycleID: nil,
            source: "whoop5_local_v2",
            sourceArchive: nil,
            sourceUpdatedAt: "2026-09-05T16:23:00Z"
        )

        XCTAssertFalse(partial.hasCompletePrimarySleepMetrics)
        XCTAssertTrue(complete.hasCompletePrimarySleepMetrics)
    }

    func testFullerCoherentOffloadRepairsPrematureLocalNight() {
        XCTAssertTrue(
            WhoopStore.shouldReplaceLocalSleep(
                existingDurationMinutes: 230.4,
                candidateDurationMinutes: 512
            ))
    }

    func testPartialOffloadCannotShrinkStoredNight() {
        XCTAssertFalse(
            WhoopStore.shouldReplaceLocalSleep(
                existingDurationMinutes: 512,
                candidateDurationMinutes: 230.4
            ))
    }

    func testCadenceJitterDoesNotRewriteSettledNight() {
        XCTAssertFalse(
            WhoopStore.shouldReplaceLocalSleep(
                existingDurationMinutes: 512,
                candidateDurationMinutes: 512.5
            ))
    }

    func testHeartRateFreshnessRejectsOldCachedReading() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(
            WhoopHandshakeProbe.heartRateIsFresh(
                receivedAt: now.addingTimeInterval(-30),
                now: now
            ))
        XCTAssertFalse(
            WhoopHandshakeProbe.heartRateIsFresh(
                receivedAt: now.addingTimeInterval(-91),
                now: now
            ))
        XCTAssertFalse(
            WhoopHandshakeProbe.heartRateIsFresh(
                receivedAt: nil,
                now: now
            ))
    }

    func testPacketReplaySignatureIncludesCharacteristicAndPayload() throws {
        let peripheral = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let otherPeripheral = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let payload = Data([0xAA, 0x01, 0x02])
        let first = WhoopStore.packetSignature(
            peripheralID: peripheral, characteristicUUID: "FD4B0003", payload: payload)
        let repeated = WhoopStore.packetSignature(
            peripheralID: peripheral, characteristicUUID: "fd4b0003", payload: payload)
        let differentCharacteristic = WhoopStore.packetSignature(
            peripheralID: peripheral, characteristicUUID: "FD4B0004", payload: payload)
        let differentPayload = WhoopStore.packetSignature(
            peripheralID: peripheral,
            characteristicUUID: "FD4B0003",
            payload: Data([0xAA, 0x01, 0x03])
        )
        let differentPeripheral = WhoopStore.packetSignature(
            peripheralID: otherPeripheral,
            characteristicUUID: "FD4B0003",
            payload: payload
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first, differentCharacteristic)
        XCTAssertNotEqual(first, differentPayload)
        XCTAssertNotEqual(first, differentPeripheral)
    }

    func testVersion26PPGDecoderPreservesSignedWaveformAndChannel() {
        let expected = (0..<24).map { Int16($0 - 12) }
        let frame = version26Frame(timestamp: 1_800_000_000, channel: 39, samples: expected)

        let decoded = WhoopDecodedPPG.decode(frame)

        XCTAssertEqual(decoded?.sampleAt.timeIntervalSince1970, 1_800_000_000)
        XCTAssertEqual(decoded?.channel, 39)
        XCTAssertEqual(decoded?.samples, expected)
    }

    func testVersion26PPGDecoderRejectsCorruptCRC() {
        var frame = version26Frame(
            timestamp: 1_800_000_000,
            channel: 1,
            samples: Array(repeating: 1, count: 24)
        )
        frame[30] ^= 0xFF

        XCTAssertNil(WhoopDecodedPPG.decode(frame))
    }

    func testStandardHeartRateDecoderConverts1024HzRRUnits() {
        let decoded = WhoopDecodedRealtime.decodeStandardHeartRate(
            Data([0x10, 60, 0x00, 0x04, 0x00, 0x02])
        )

        XCTAssertEqual(decoded?.heartRate, 60)
        XCTAssertEqual(decoded?.rrIntervals, [1_000, 500])
        XCTAssertEqual(decoded?.source, "standard_2a37")
    }

    func testStandardHeartRateDecoderHandlesUInt16AndEnergyField() {
        let decoded = WhoopDecodedRealtime.decodeStandardHeartRate(
            Data([0x19, 0x04, 0x01, 0x34, 0x12, 0x00, 0x04])
        )

        XCTAssertEqual(decoded?.heartRate, 260)
        XCTAssertEqual(decoded?.rrIntervals, [1_000])
    }

    func testWhoop5RealtimeDecoderRequiresCRCAndPreservesTimestamp() {
        var bytes = WhoopTestFrameFactory.frame(length: 24, type: 40, version: 1)
        let timestamp: UInt32 = 1_800_000_000
        bytes[10] = UInt8(truncatingIfNeeded: timestamp)
        bytes[11] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[12] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[13] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[16] = 61
        bytes[17] = 1
        bytes[18] = 0x84
        bytes[19] = 0x03
        WhoopTestFrameFactory.finishChecksums(&bytes)

        let decoded = WhoopDecodedRealtime.decodeWhoop5Realtime(Data(bytes))
        XCTAssertEqual(decoded?.deviceTimestamp, timestamp)
        XCTAssertEqual(decoded?.heartRate, 61)
        XCTAssertEqual(decoded?.rrIntervals, [900])

        bytes[18] ^= 0x01
        XCTAssertNil(WhoopDecodedRealtime.decodeWhoop5Realtime(Data(bytes)))
    }

    func testEmptyLegacyDatabaseMigratesIdempotentlyToCurrentSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("sleep.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }
        do {
            let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(scalarInt(database, sql: "PRAGMA user_version"), 10)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('whoop_decode_failure','whoop_latest_heart_rate','whoop_ppg_packet','whoop_store_metadata')"
            ), 4)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='whoop_decode_result'"
            ), 0)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM pragma_table_info('whoop_ppg_packet') WHERE name='decoder_version'"
            ), 1)
        XCTAssertEqual(
            scalarInt(
                database,
                sql: "SELECT COUNT(*) FROM pragma_table_info('heart_rate_sample') WHERE name='id'"
            ), 0)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM pragma_table_info('daily_health_metric') WHERE name IN ('sleep_start_at','sleep_end_at','sleep_start_minute','sleep_end_minute','sleep_need_minutes','sleep_consistency_percentage','sleep_efficiency_percentage','sleep_sufficiency_percentage')"
            ), 8)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('whoop_api_source_record','whoop_api_numeric_metric')"
            ), 2)
        XCTAssertGreaterThanOrEqual(
            scalarInt(
                database,
                sql: "SELECT COUNT(*) FROM whoop_time_zone_observation"
            ), 1)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM pragma_table_info('whoop_historical_sample') WHERE name IN ('step_motion_counter','step_cadence_raw','motion_class_raw','step_utc_offset_seconds','step_date_key')"
            ), 5)
        XCTAssertEqual(
            scalarInt(
                database,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='whoop_daily_step_metric'"
            ), 1)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('whoop_official_daily_metric','whoop_daily_recovery_metric')"
            ), 2)
    }

    func testVersion18DecoderPreservesMotionFieldsAndRejectsCorruption() {
        var frame = version18Frame(
            timestamp: 1_800_000_000,
            sleepState: 2,
            stepCounter: 54_321,
            cadenceRaw: 73,
            motionClassRaw: 4
        )

        let decoded = WhoopDecodedHistorical.decode(frame)
        XCTAssertEqual(decoded?.stepMotionCounter, 54_321)
        XCTAssertEqual(decoded?.stepCadenceRaw, 73)
        XCTAssertEqual(decoded?.motionClassRaw, 4)

        frame[57] ^= 0x01
        XCTAssertNil(WhoopDecodedHistorical.decode(frame))
    }

    func testStepSummaryCountsNormalAndWrappedDeltas() {
        let summary = WhoopStepDaySummary.summarize([
            WhoopStepCounterSample(timestamp: 0, counter: 65_532),
            WhoopStepCounterSample(timestamp: 1, counter: 65_534),
            WhoopStepCounterSample(timestamp: 2, counter: 2),
            WhoopStepCounterSample(timestamp: 3, counter: 5),
        ])

        XCTAssertEqual(summary.stepCount, 9)
        XCTAssertEqual(summary.counterWrapCount, 1)
        XCTAssertEqual(summary.rejectedDeltaCount, 0)
        XCTAssertEqual(summary.sampleCount, 4)
        XCTAssertEqual(summary.coverageFraction, 1, accuracy: 0.001)
    }

    func testStepSummaryRejectsImplausibleResetAndTracksCoverage() {
        let summary = WhoopStepDaySummary.summarize([
            WhoopStepCounterSample(timestamp: 0, counter: 30_000),
            WhoopStepCounterSample(timestamp: 10, counter: 2),
            WhoopStepCounterSample(timestamp: 11, counter: 5),
        ])

        XCTAssertEqual(summary.stepCount, 3)
        XCTAssertEqual(summary.rejectedDeltaCount, 1)
        XCTAssertEqual(summary.gapSeconds, 9)
        XCTAssertEqual(summary.spanSeconds, 12)
        XCTAssertEqual(summary.coverageFraction, 0.25, accuracy: 0.001)
    }

    func testCompletedOffloadMaterializesDailyStepsWithProvenance() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("sleep.sqlite3"),
            runBackgroundDecoding: false
        )
        defer { store.shutdownForTesting() }
        let peripheral = UUID()
        let timestamp = UInt32(Date().timeIntervalSince1970)

        let first = try await append(
            version18Frame(timestamp: timestamp, sleepState: 0, stepCounter: 100),
            store: store, peripheral: peripheral, sessionID: nil
        )
        XCTAssertTrue(first.success)
        let second = try await append(
            version18Frame(timestamp: timestamp + 1, sleepState: 0, stepCounter: 103),
            store: store, peripheral: peripheral, sessionID: nil
        )
        XCTAssertTrue(second.success)
        let completion = try await append(
            metadataFrame(type: 3),
            store: store, peripheral: peripheral, sessionID: nil
        )
        XCTAssertTrue(completion.success)

        let records: [DailyStepRecord] = try await withCheckedThrowingContinuation { continuation in
            store.loadDailyStepRecords { continuation.resume(with: $0) }
        }
        let record = try XCTUnwrap(records.last)
        XCTAssertEqual(record.stepCount, 3)
        XCTAssertEqual(record.sampleCount, 2)
        XCTAssertEqual(record.coverageFraction, 1, accuracy: 0.001)
        XCTAssertEqual(record.rejectedDeltaCount, 0)
        XCTAssertEqual(record.source, "whoop5_v18_step_counter")
        XCTAssertEqual(record.algorithmVersion, WhoopStepDaySummary.algorithmVersion)
    }

    func testStepMaterializationUsesPublishedWakeInsteadOfMidnight() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }

        let parser = ISO8601DateFormatter()
        let firstWake = try XCTUnwrap(parser.date(from: "2027-01-14T15:00:00Z"))
        let nextWake = try XCTUnwrap(parser.date(from: "2027-01-15T15:00:00Z"))
        try insertWakeBoundary(dateKey: "2027-01-14", wokeAt: firstWake, databaseURL: databaseURL)
        try insertWakeBoundary(dateKey: "2027-01-15", wokeAt: nextWake, databaseURL: databaseURL)

        let peripheral = UUID()
        let samples: [(TimeInterval, UInt16)] = [
            (firstWake.timeIntervalSince1970 + 100, 100),
            // 2 a.m. local civil time: still Jan 14's physiological day.
            (nextWake.timeIntervalSince1970 - 8 * 60 * 60, 150),
            (nextWake.timeIntervalSince1970, 150),
            (nextWake.timeIntervalSince1970 + 100, 160),
        ]
        for (timestamp, counter) in samples {
            let result = try await append(
                version18Frame(
                    timestamp: UInt32(timestamp),
                    sleepState: 0,
                    stepCounter: counter
                ),
                store: store,
                peripheral: peripheral,
                sessionID: nil
            )
            XCTAssertTrue(result.success)
        }
        let completion = try await append(
            metadataFrame(type: 3),
            store: store,
            peripheral: peripheral,
            sessionID: nil
        )
        XCTAssertTrue(completion.success)

        let records: [DailyStepRecord] = try await withCheckedThrowingContinuation { continuation in
            store.loadDailyStepRecords { continuation.resume(with: $0) }
        }
        XCTAssertEqual(records.map(\.dateKey), ["2027-01-14", "2027-01-15"])
        XCTAssertEqual(records.map(\.stepCount), [50, 10])
    }

    func testMotionBackfillRebuildsPreviouslyDecodedDaysAfterRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let peripheral = UUID()
        let timestamp = UInt32(Date().timeIntervalSince1970)

        var initialStore: WhoopStore? = WhoopStore(
            databaseURL: databaseURL,
            runBackgroundDecoding: false
        )
        _ = try await append(
            version18Frame(timestamp: timestamp, sleepState: 0, stepCounter: 100),
            store: try XCTUnwrap(initialStore),
            peripheral: peripheral,
            sessionID: nil
        )
        _ = try await append(
            version18Frame(timestamp: timestamp + 1, sleepState: 0, stepCounter: 103),
            store: try XCTUnwrap(initialStore),
            peripheral: peripheral,
            sessionID: nil
        )

        // A restart requires the original SQLite connection to be closed.
        // Explicit shutdown avoids relying on ARC timing across async work.
        initialStore?.shutdownForTesting()
        initialStore = nil

        let restarted = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: true)
        defer { restarted.shutdownForTesting() }
        var records: [DailyStepRecord] = []
        for _ in 0..<100 {
            records = try await withCheckedThrowingContinuation { continuation in
                restarted.loadDailyStepRecords { continuation.resume(with: $0) }
            }
            if !records.isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        let record = try XCTUnwrap(records.last)
        XCTAssertEqual(record.stepCount, 3)
        XCTAssertEqual(record.sampleCount, 2)
    }

    func testOnlineBackupIncludesCommittedWALData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.sqlite3")
        let snapshotURL = directory.appendingPathComponent("snapshot.sqlite3")

        var source: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                sourceURL.path,
                &source,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
                nil
            ),
            SQLITE_OK
        )
        guard let source else { return }
        defer { sqlite3_close(source) }
        XCTAssertEqual(sqlite3_exec(source, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(source, "CREATE TABLE evidence(value TEXT NOT NULL)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(source, "PRAGMA user_version=6", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(source, "INSERT INTO evidence VALUES ('retained')", nil, nil, nil), SQLITE_OK)

        XCTAssertTrue(WhoopStore.copySQLiteDatabase(source: source, destinationURL: snapshotURL))
        var snapshot: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(snapshotURL.path, &snapshot, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let snapshot { sqlite3_close(snapshot) } }
        XCTAssertEqual(scalarInt(snapshot, sql: "PRAGMA user_version"), 6)
        XCTAssertEqual(scalarInt(snapshot, sql: "SELECT COUNT(*) FROM evidence"), 1)
        XCTAssertEqual(scalarText(snapshot, sql: "PRAGMA quick_check"), "ok")
    }

    func testHistoricalInsertReleasesCachedTimezoneReaderForCheckpoint() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }

        let packet = version18Frame(
            timestamp: UInt32(Date().timeIntervalSince1970),
            sleepState: 0,
            stepCounter: 100
        )
        let persisted = try await append(
            packet,
            store: store,
            peripheral: UUID(),
            sessionID: nil
        )
        XCTAssertTrue(persisted.success)

        var checkpointConnection: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                databaseURL.path,
                &checkpointConnection,
                SQLITE_OPEN_READWRITE,
                nil
            ),
            SQLITE_OK
        )
        guard let checkpointConnection else { throw XCTSkip("Could not open checkpoint fixture") }
        defer { sqlite3_close(checkpointConnection) }
        var logFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        XCTAssertEqual(
            sqlite3_wal_checkpoint_v2(
                checkpointConnection,
                nil,
                SQLITE_CHECKPOINT_TRUNCATE,
                &logFrames,
                &checkpointedFrames
            ),
            SQLITE_OK,
            "A cached SELECT must not retain a reader after packet persistence finishes"
        )
    }

    func testRealtimeStorageKeepsLatestValueWithoutIndexingEmptyRRHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }
        let peripheral = UUID()
        let repeatedPacket = Data([0xAA, 0x01, 0x28])

        let first = await appendRealtime(
            repeatedPacket,
            heartRate: 60,
            rrIntervals: [],
            deliveredAt: Date(timeIntervalSince1970: 100),
            store: store,
            peripheral: peripheral
        )
        let duplicate = await appendRealtime(
            repeatedPacket,
            heartRate: 61,
            rrIntervals: [],
            deliveredAt: Date(timeIntervalSince1970: 200),
            store: store,
            peripheral: peripheral
        )
        let withRR = await appendRealtime(
            Data([0xAA, 0x01, 0x29]),
            heartRate: 62,
            rrIntervals: [900],
            deliveredAt: Date(timeIntervalSince1970: 300),
            store: store,
            peripheral: peripheral
        )
        let stale = await appendRealtime(
            Data([0xAA, 0x01, 0x2A]),
            heartRate: 70,
            rrIntervals: [],
            deliveredAt: Date(timeIntervalSince1970: 250),
            store: store,
            peripheral: peripheral
        )
        let invalidLatest = await appendRealtime(
            Data([0xAA, 0x01, 0x2B]),
            heartRate: 0,
            rrIntervals: [],
            deliveredAt: Date(timeIntervalSince1970: 400),
            store: store,
            peripheral: peripheral
        )

        XCTAssertTrue(first.success)
        XCTAssertTrue(duplicate.success)
        XCTAssertTrue(withRR.success)
        XCTAssertTrue(stale.success)
        XCTAssertTrue(invalidLatest.success)
        let latest: WhoopLatestHeartRateSample? = await withCheckedContinuation { continuation in
            store.loadLatestHeartRateSample { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(latest?.heartRate, 62)
        XCTAssertEqual(latest?.receivedAt, Date(timeIntervalSince1970: 300))

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(scalarInt(database, sql: "SELECT COUNT(*) FROM whoop_raw_packet"), 4)
        XCTAssertEqual(scalarInt(database, sql: "SELECT SUM(duplicate_count) FROM whoop_packet_replay"), 1)
        XCTAssertEqual(scalarInt(database, sql: "SELECT COUNT(*) FROM heart_rate_sample"), 1)
    }

    func testMigrationSnapshotRemovesStaleTemporarySidecars() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("sleep.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version=7", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let backupDirectory = directory.appendingPathComponent("migration-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let temporary = backupDirectory.appendingPathComponent(".migration-backup-in-progress.sqlite3")
        for path in [temporary.path, temporary.path + "-wal", temporary.path + "-shm"] {
            try Data("stale".utf8).write(to: URL(fileURLWithPath: path))
        }

        do {
            let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path + "-shm"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: backupDirectory.appendingPathComponent("sleep-v7-before-v10.sqlite3").path
            ))
    }

    func testSchema10MigrationCompactsRealtimeProjectionAndDecodeLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        guard let database else { throw XCTSkip("Could not open schema fixture") }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                PRAGMA foreign_keys=OFF;
                DROP TABLE heart_rate_sample;
                DROP TABLE whoop_latest_heart_rate;
                DROP TABLE whoop_decode_failure;
                DROP TABLE whoop_ppg_packet;
                CREATE TABLE heart_rate_sample (
                    id TEXT PRIMARY KEY,
                    source_packet_id TEXT NOT NULL,
                    received_at REAL NOT NULL,
                    device_timestamp INTEGER,
                    heart_rate INTEGER NOT NULL,
                    rr_intervals_json TEXT NOT NULL,
                    source TEXT NOT NULL,
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                );
                CREATE INDEX heart_rate_sample_received_at
                    ON heart_rate_sample(received_at);
                CREATE INDEX heart_rate_sample_source_time
                    ON heart_rate_sample(source, device_timestamp, received_at);
                CREATE INDEX heart_rate_sample_source_received
                    ON heart_rate_sample(source, received_at);
                CREATE TABLE whoop_decode_result (
                    source_packet_id TEXT NOT NULL,
                    decoder_version INTEGER NOT NULL,
                    protocol_version INTEGER,
                    stream TEXT NOT NULL,
                    status TEXT NOT NULL,
                    error TEXT,
                    decoded_at REAL NOT NULL,
                    PRIMARY KEY(source_packet_id, decoder_version),
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                );
                CREATE INDEX whoop_decode_result_status
                    ON whoop_decode_result(decoder_version, status);
                CREATE TABLE whoop_ppg_packet (
                    source_packet_id TEXT PRIMARY KEY,
                    sample_at REAL NOT NULL,
                    channel INTEGER NOT NULL CHECK(channel BETWEEN 1 AND 255),
                    sample_rate_hz REAL NOT NULL,
                    samples_i16_le BLOB NOT NULL,
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                );
                CREATE INDEX whoop_ppg_packet_sample_at
                    ON whoop_ppg_packet(sample_at, channel);
                INSERT INTO whoop_raw_packet
                    (id, received_at, delivery_sequence, peripheral_id,
                     characteristic_uuid, frame_type, crc_valid, payload)
                VALUES
                    ('p1', 100, 1, 'strap', 'FD4B0003', 40, 1, X'01'),
                    ('p2', 200, 2, 'strap', 'FD4B0003', 40, 1, X'02');
                INSERT INTO heart_rate_sample
                    (id, source_packet_id, received_at, device_timestamp,
                     heart_rate, rr_intervals_json, source)
                VALUES
                    ('p1', 'p1', 100, 100, 60, '[]', 'whoop5_type40'),
                    ('p2', 'p2', 200, 200, 61, '[900]', 'whoop5_type40');
                INSERT INTO whoop_decode_result
                    (source_packet_id, decoder_version, protocol_version,
                     stream, status, error, decoded_at)
                VALUES
                    ('p1', 2, 26, 'optical_ppg', 'decoded', NULL, 100),
                    ('p2', 3, 99, 'historical_unknown', 'unsupported', 'fixture', 200);
                INSERT INTO whoop_ppg_packet
                    (source_packet_id, sample_at, channel, sample_rate_hz, samples_i16_le)
                VALUES ('p1', 100, 1, 24, X'0102');
                PRAGMA user_version=9;
                """,
                nil,
                nil,
                nil
            ), SQLITE_OK)
        sqlite3_close(database)

        do {
            let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }

        var migrated: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &migrated, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let migrated { sqlite3_close(migrated) } }
        XCTAssertEqual(scalarInt(migrated, sql: "PRAGMA user_version"), 10)
        XCTAssertEqual(scalarInt(migrated, sql: "PRAGMA freelist_count"), 0)
        XCTAssertEqual(scalarInt(migrated, sql: "SELECT COUNT(*) FROM heart_rate_sample"), 1)
        XCTAssertEqual(
            scalarInt(migrated, sql: "SELECT COUNT(*) FROM heart_rate_sample WHERE rr_intervals_json='[]'"),
            0
        )
        XCTAssertEqual(
            scalarInt(migrated, sql: "SELECT heart_rate FROM whoop_latest_heart_rate WHERE singleton=1"),
            61
        )
        XCTAssertEqual(scalarInt(migrated, sql: "SELECT COUNT(*) FROM whoop_decode_failure"), 1)
        XCTAssertEqual(
            scalarInt(migrated, sql: "SELECT decoder_version FROM whoop_ppg_packet WHERE source_packet_id='p1'"),
            2
        )
        XCTAssertEqual(
            scalarText(migrated, sql: "SELECT hex(samples_i16_le) FROM whoop_ppg_packet WHERE source_packet_id='p1'"),
            "0102"
        )
        XCTAssertEqual(
            scalarInt(
                migrated,
                sql:
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='whoop_decode_result'"
            ), 0)
        XCTAssertEqual(scalarText(migrated, sql: "PRAGMA foreign_key_check"), nil)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    "migration-backups/sleep-v9-before-v10.sqlite3"
                ).path
            ))
    }

    func testMigrationBackupPruningKeepsExactRollbackPointAndUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let retained = directory.appendingPathComponent("sleep-v9-before-v10.sqlite3")
        let old = directory.appendingPathComponent("sleep-v8-before-v9.sqlite3")
        let unrelated = directory.appendingPathComponent("manual-recovery.sqlite3")
        for url in [retained, old, unrelated, URL(fileURLWithPath: old.path + "-wal")] {
            try Data("synthetic".utf8).write(to: url)
        }

        WhoopStore.pruneMigrationBackups(in: directory, keeping: retained)

        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testOfficialMetricsSeedPreservesTargetsBaselinesAndProvenance() throws {
        let json = """
            {
              "formatVersion": 1,
              "source": "whoop_private_ios_api",
              "sourceArchive": "private-api-example",
              "sourceManifestSHA256": "manifest-sha",
              "sourceDatabaseSHA256": "database-sha",
              "coverageStart": "2025-10-15",
              "coverageEnd": "2026-09-07",
              "daily": [{
                "dateKey": "2026-08-31",
                "officialRecoveryScore": 91,
                "officialSteps": 7493,
                "officialDayStrain": 12.4,
                "dayStrainTarget": 13.2,
                "stepsBaseline": 8100,
                "hrv": 82.5,
                "hrvBaseline": 77.2,
                "rhr": 48,
                "rhrBaseline": 50.1,
                "respiratoryRate": 14.2,
                "respiratoryRateBaseline": 14.0,
                "sleepPerformance": 96,
                "sleepPerformanceBaseline": 91,
                "sourceRecoverySHA256": "recovery-sha",
                "sourceStrainSHA256": "strain-sha"
              }]
            }
            """

        let seed = try JSONDecoder().decode(OfficialMetricsSeed.self, from: Data(json.utf8))

        XCTAssertEqual(seed.daily.count, 1)
        XCTAssertEqual(seed.daily[0].officialRecoveryScore, 91)
        XCTAssertEqual(seed.daily[0].officialSteps, 7_493)
        XCTAssertEqual(seed.daily[0].hrvBaseline, 77.2)
        XCTAssertEqual(seed.daily[0].sourceStrainSHA256, "strain-sha")
    }

    func testRecoveryFeaturesArePastOnlyAndComplete() throws {
        func record(_ date: String, hrv: Double, rhr: Double, score: Double) -> DailyHealthRecord {
            DailyHealthRecord(
                dateKey: date,
                sleepScore: score,
                sleepDurationMinutes: 480,
                hrvRMSSDMilliseconds: hrv,
                restingHeartRateBPM: rhr,
                sleepID: date,
                cycleID: nil,
                source: "test",
                sourceArchive: nil,
                sourceUpdatedAt: date,
                sleepStartAt: nil,
                sleepEndAt: nil,
                sleepStartMinute: 1_410,
                sleepEndMinute: 420,
                sleepNeedMinutes: nil,
                sleepConsistencyPercentage: nil,
                sleepEfficiencyPercentage: 95,
                sleepSufficiencyPercentage: nil
            )
        }
        let current = record("2026-09-07", hrv: 80, rhr: 48, score: 96)
        let past = record("2026-09-06", hrv: 70, rhr: 51, score: 90)
        let future = record("2026-09-08", hrv: 1, rhr: 200, score: 1)

        let features = try XCTUnwrap(
            RecoveryScoreFeatureBuilder.features(
                current: current,
                history: [past, future],
                stepsByDate: ["2026-09-06": 8_000, "2026-09-07": 10_000]
            ))

        XCTAssertEqual(features.count, RecoveryScoreFeatureBuilder.featureCount)
        XCTAssertEqual(features[50], 80)
        XCTAssertEqual(features[51], 48)
        XCTAssertEqual(features[52], 10_000)
        XCTAssertEqual(features[54], 70)
        XCTAssertEqual(features[55], 51)
        XCTAssertEqual(features[89], 70)
    }

    func testSerializedRecoveryModelBlendsAndBoundsPrediction() throws {
        let count = RecoveryScoreFeatureBuilder.featureCount
        let zeros = Array(repeating: 0.0, count: count)
        let ones = Array(repeating: 1.0, count: count)
        let payload: [String: Any] = [
            "version": "synthetic-recovery",
            "featureVersion": RecoveryScoreFeatureBuilder.version,
            "featureCount": count,
            "boostedWeight": 0.7,
            "imputerMedians": zeros,
            "boostedModel": [
                "initialPrediction": 80.0, "learningRate": 0.1, "trees": [],
            ],
            "ridgeModel": [
                "imputerMedians": zeros, "means": zeros, "scales": ones,
                "coefficients": zeros, "intercept": 20.0,
            ],
        ]
        let model = try JSONDecoder().decode(
            RecoveryScoreModelBundle.self,
            from: JSONSerialization.data(withJSONObject: payload)
        )
        var features = zeros
        features[52] = .nan

        let prediction = try XCTUnwrap(model.prediction(features))

        XCTAssertEqual(prediction.score, 62, accuracy: 0.0001)
        XCTAssertEqual(prediction.confidence, 0.82)
    }

    func testOfficialStepsOverrideOverlappingLocalDayAndJoinLocalTail() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                INSERT INTO whoop_official_daily_metric
                    (date_key, official_recovery_score, official_steps,
                     source_archive, source_manifest_sha256, imported_at)
                VALUES ('2026-08-31', 91, 7493, 'archive', 'manifest', 0);
                INSERT INTO whoop_daily_step_metric
                    (date_key, peripheral_id, step_count, sample_count, span_seconds,
                     coverage_fraction, gap_seconds, counter_wrap_count, rejected_delta_count,
                     source, algorithm_version, derived_at)
                VALUES
                    ('2026-08-31', 'strap', 7000, 1, 1, 1, 0, 0, 0, 'local', 1, 0),
                    ('2026-09-01', 'strap', 8123, 1, 1, 1, 0, 0, 0, 'local', 1, 0);
                """, nil, nil, nil), SQLITE_OK)

        let records: [DailyStepRecord] = try await withCheckedThrowingContinuation { continuation in
            store.loadDailyStepRecords { continuation.resume(with: $0) }
        }

        XCTAssertEqual(records.map(\.stepCount), [7_493, 8_123])
        XCTAssertEqual(records.map(\.source), ["whoop_private_ios_api", "local"])
        let recovery: [DailyRecoveryRecord] = try await withCheckedThrowingContinuation { continuation in
            store.loadDailyRecoveryRecords { continuation.resume(with: $0) }
        }
        XCTAssertEqual(recovery.map(\.score), [91])
        XCTAssertEqual(recovery.map(\.source), ["whoop_private_ios_api"])
    }

    func testSleepScoreFeaturesCaptureDurationEfficiencyAndRecentTiming() {
        let history = [
            SleepScoreNight(
                dateKey: "2026-09-05", durationMinutes: 450,
                efficiencyPercentage: 92, startMinute: 1_380, endMinute: 390
            ),
            SleepScoreNight(
                dateKey: "2026-09-06", durationMinutes: 480,
                efficiencyPercentage: 95, startMinute: 1_410, endMinute: 420
            ),
        ]
        let current = SleepScoreNight(
            dateKey: "2026-09-07", durationMinutes: 510,
            efficiencyPercentage: 97, startMinute: 1_425, endMinute: 435
        )

        let features = SleepScoreFeatureBuilder.features(current: current, history: history)

        XCTAssertEqual(features.count, 50)
        XCTAssertEqual(features[0], 510)
        XCTAssertEqual(features[1], 97)
        XCTAssertEqual(features[6], 480)
        XCTAssertEqual(features[7], 95)
        XCTAssertGreaterThan(features.last ?? 0, 95)
    }

    func testFallbackSleepScoreIsBounded() {
        XCTAssertEqual(
            WhoopStore.fallbackSleepScore(
                durationMinutes: 1_000,
                efficiencyPercentage: 100,
                timingAgreementPercentage: 100
            ),
            99
        )
        XCTAssertEqual(
            WhoopStore.fallbackSleepScore(
                durationMinutes: 0,
                efficiencyPercentage: 0,
                timingAgreementPercentage: 0
            ),
            0
        )
    }

    func testSerializedSleepScoreModelPredictsForestSVREnsemble() throws {
        let features = Array(repeating: 0.0, count: SleepScoreFeatureBuilder.featureCount)
        let payload: [String: Any] = [
            "version": "synthetic",
            "featureVersion": SleepScoreFeatureBuilder.version,
            "directWeight": 0.1,
            "extraTreesWeight": 0.75,
            "trees": [
                [
                    "childrenLeft": [-1], "childrenRight": [-1],
                    "features": [-2], "thresholds": [-2.0], "values": [80.0],
                ]
            ],
            "svr": [
                "means": features, "scales": Array(repeating: 1.0, count: features.count),
                "supportVectors": [features], "dualCoefficients": [0.0],
                "intercept": 100.0, "gamma": 0.1,
            ],
            "needModel": [
                "initialPrediction": 500.0, "learningRate": 0.1, "trees": [],
            ],
            "consistencyModel": [
                "initialPrediction": 80.0, "learningRate": 0.1, "trees": [],
            ],
            "pillarSVR": [
                "means": [0.0, 0.0, 0.0], "scales": [1.0, 1.0, 1.0],
                "supportVectors": [[0.0, 0.0, 0.0]], "dualCoefficients": [0.0],
                "intercept": 100.0, "gamma": 0.1,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let model = try JSONDecoder().decode(SleepScoreModelBundle.self, from: data)

        let prediction = try XCTUnwrap(model.prediction(features))
        XCTAssertEqual(prediction.score, 98.5, accuracy: 0.0001)
        XCTAssertEqual(prediction.sleepNeedMinutes, 500, accuracy: 0.0001)
        XCTAssertEqual(prediction.consistencyPercentage, 80, accuracy: 0.0001)
        XCTAssertEqual(prediction.sufficiencyPercentage, 0, accuracy: 0.0001)
    }

    func testOffloadCompletionRequiresDurableCRCValidCompletionAfterHistory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("sleep.sqlite3"),
            runBackgroundDecoding: false
        )
        defer { store.shutdownForTesting() }
        let peripheral = UUID()
        let sessionID = try await beginOffload(store: store, peripheral: peripheral)
        let history = version18Frame(timestamp: 1_800_000_000, sleepState: 2)

        let historyResult = try await append(
            history,
            store: store,
            peripheral: peripheral,
            sessionID: sessionID
        )
        XCTAssertTrue(historyResult.success)
        XCTAssertFalse(store.completedOffloadCoversLatestHistoryForTesting())

        let completion = metadataFrame(type: 3)
        let completionResult = try await append(
            completion,
            store: store,
            peripheral: peripheral,
            sessionID: sessionID
        )
        XCTAssertTrue(completionResult.success)
        XCTAssertTrue(store.completedOffloadCoversLatestHistoryForTesting())

        let newerHistoryResult = try await append(
            version18Frame(timestamp: 1_800_000_100, sleepState: 2),
            store: store,
            peripheral: peripheral,
            sessionID: nil
        )
        XCTAssertTrue(newerHistoryResult.success)
        XCTAssertFalse(store.completedOffloadCoversLatestHistoryForTesting())
    }

    func testCorruptCompletionCannotCompleteOffload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WhoopStore(
            databaseURL: directory.appendingPathComponent("sleep.sqlite3"),
            runBackgroundDecoding: false
        )
        defer { store.shutdownForTesting() }
        let peripheral = UUID()
        let sessionID = try await beginOffload(store: store, peripheral: peripheral)
        let historyResult = try await append(
            version18Frame(timestamp: 1_800_000_000, sleepState: 2),
            store: store,
            peripheral: peripheral,
            sessionID: sessionID
        )
        XCTAssertTrue(historyResult.success)
        var completion = metadataFrame(type: 3)
        completion[11] ^= 0x01
        let completionResult = try await append(
            completion,
            store: store,
            peripheral: peripheral,
            sessionID: sessionID
        )
        XCTAssertTrue(completionResult.success)

        XCTAssertFalse(store.completedOffloadCoversLatestHistoryForTesting())
    }

    func testSameHistoricalTimestampFromDifferentStrapsDoesNotCollide() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sleep.sqlite3")
        let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
        defer { store.shutdownForTesting() }
        let packet = version18Frame(timestamp: 1_800_000_000, sleepState: 2)
        let firstPeripheral = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondPeripheral = try XCTUnwrap(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))

        let first = try await append(
            packet,
            store: store,
            peripheral: firstPeripheral,
            sessionID: nil
        )
        let second = try await append(
            packet,
            store: store,
            peripheral: secondPeripheral,
            sessionID: nil
        )
        XCTAssertTrue(first.success)
        XCTAssertTrue(second.success)

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(
            scalarInt(database, sql: "SELECT COUNT(*) FROM whoop_historical_sample"),
            2
        )
        XCTAssertLessThanOrEqual(
            scalarInt(database, sql: "SELECT MAX(length(id)) FROM whoop_raw_packet"),
            8,
            "New raw evidence should use compact sequence-derived IDs, not UUID text"
        )
    }

    private func dailyHealthRecord(dateKey: String) -> DailyHealthRecord {
        DailyHealthRecord(
            dateKey: dateKey,
            sleepScore: 88,
            sleepDurationMinutes: 480,
            hrvRMSSDMilliseconds: 64,
            restingHeartRateBPM: 52,
            sleepID: "synthetic-\(dateKey)",
            cycleID: nil,
            source: "synthetic",
            sourceArchive: nil,
            sourceUpdatedAt: "2026-09-09T12:00:00Z"
        )
    }

    private func dailyStepRecord(dateKey: String, stepCount: Int) -> DailyStepRecord {
        DailyStepRecord(
            dateKey: dateKey,
            stepCount: stepCount,
            sampleCount: 2,
            spanSeconds: 2,
            coverageFraction: 1,
            gapSeconds: 0,
            counterWrapCount: 0,
            rejectedDeltaCount: 0,
            firstSampleAt: nil,
            lastSampleAt: nil,
            source: "synthetic",
            algorithmVersion: WhoopStepDaySummary.algorithmVersion
        )
    }

    private func insertWakeBoundary(
        dateKey: String,
        wokeAt: Date,
        databaseURL: URL
    ) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &database), SQLITE_OK)
        guard let database else { throw XCTSkip("Could not open SQLite fixture") }
        defer { sqlite3_close(database) }
        let sql = """
            INSERT INTO daily_health_metric
            (date_key, source, source_updated_at, imported_at, sleep_end_at)
            VALUES (?, 'synthetic', '2027-01-15T12:00:00Z', 0, ?)
            """
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(database, sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else { throw XCTSkip("Could not prepare SQLite fixture") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, dateKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        let wake = ISO8601DateFormatter().string(from: wokeAt)
        sqlite3_bind_text(statement, 2, wake, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    private func row(at timestamp: TimeInterval, state: Int) -> WhoopStore.HistoricalRow {
        WhoopStore.HistoricalRow(
            timestamp: timestamp,
            heartRate: 55,
            sleepState: SleepState(rawValue: state)
        )
    }

    private func version26Frame(
        timestamp: UInt32,
        channel: UInt8,
        samples: [Int16]
    ) -> Data {
        precondition(samples.count == 24)
        var bytes = [UInt8](repeating: 0, count: 88)
        bytes[0] = 0xAA
        bytes[1] = 0x01
        bytes[2] = 80
        bytes[4] = 0x01
        bytes[8] = 47
        bytes[9] = 26
        bytes[15] = UInt8(truncatingIfNeeded: timestamp)
        bytes[16] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[17] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[18] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[21] = channel
        for (index, sample) in samples.enumerated() {
            let raw = UInt16(bitPattern: sample)
            bytes[27 + index * 2] = UInt8(truncatingIfNeeded: raw)
            bytes[28 + index * 2] = UInt8(truncatingIfNeeded: raw >> 8)
        }
        let headerCRC = WhoopFrameIntegrity.crc16Modbus(bytes[0..<6])
        bytes[6] = UInt8(truncatingIfNeeded: headerCRC)
        bytes[7] = UInt8(truncatingIfNeeded: headerCRC >> 8)
        let crc = WhoopFrameIntegrity.crc32(bytes[8..<84])
        bytes[84] = UInt8(truncatingIfNeeded: crc)
        bytes[85] = UInt8(truncatingIfNeeded: crc >> 8)
        bytes[86] = UInt8(truncatingIfNeeded: crc >> 16)
        bytes[87] = UInt8(truncatingIfNeeded: crc >> 24)
        return Data(bytes)
    }

    private func version18Frame(
        timestamp: UInt32,
        sleepState: UInt8,
        stepCounter: UInt16 = 0,
        cadenceRaw: UInt8 = 0,
        motionClassRaw: UInt8 = 0
    ) -> Data {
        var bytes = WhoopTestFrameFactory.frame(length: 124, type: 47, version: 18)
        bytes[15] = UInt8(truncatingIfNeeded: timestamp)
        bytes[16] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[17] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[18] = UInt8(truncatingIfNeeded: timestamp >> 24)
        bytes[22] = 55
        bytes[57] = UInt8(truncatingIfNeeded: stepCounter)
        bytes[58] = UInt8(truncatingIfNeeded: stepCounter >> 8)
        bytes[59] = cadenceRaw
        bytes[63] = motionClassRaw
        bytes[81] = sleepState << 4
        WhoopTestFrameFactory.finishChecksums(&bytes)
        return Data(bytes)
    }

    private func metadataFrame(type: UInt8) -> Data {
        WhoopTestFrameFactory.historicalMetadata(type: type, length: 16)
    }

    private func wristEventFrame(event: UInt8, timestamp: UInt32) -> Data {
        var bytes = WhoopTestFrameFactory.frame(length: 20, type: 48, version: 1)
        bytes[10] = event
        bytes[12] = UInt8(truncatingIfNeeded: timestamp)
        bytes[13] = UInt8(truncatingIfNeeded: timestamp >> 8)
        bytes[14] = UInt8(truncatingIfNeeded: timestamp >> 16)
        bytes[15] = UInt8(truncatingIfNeeded: timestamp >> 24)
        WhoopTestFrameFactory.finishChecksums(&bytes)
        return Data(bytes)
    }

    private func beginOffload(store: WhoopStore, peripheral: UUID) async throws -> String {
        let result: String? = await withCheckedContinuation { continuation in
            store.beginHistoricalOffload(peripheralID: peripheral) {
                continuation.resume(returning: $0)
            }
        }
        return try XCTUnwrap(result)
    }

    private func append(
        _ packet: Data,
        store: WhoopStore,
        peripheral: UUID,
        sessionID: String?
    ) async throws -> WhoopPacketPersistenceResult {
        let result: WhoopPacketPersistenceResult = await withCheckedContinuation { continuation in
            store.append(
                packet: packet,
                peripheralID: peripheral,
                characteristicUUID: "FD4B0003",
                frameType: packet.count > 8 ? FrameType(rawValue: packet[8]) : nil,
                realtime: nil,
                historical: WhoopDecodedHistorical.decode(packet),
                offloadSessionID: sessionID
            ) {
                continuation.resume(returning: $0)
            }
        }
        return result
    }

    private func appendRealtime(
        _ packet: Data,
        heartRate: Int,
        rrIntervals: [UInt16],
        deliveredAt: Date,
        store: WhoopStore,
        peripheral: UUID
    ) async -> WhoopPacketPersistenceResult {
        await withCheckedContinuation { continuation in
            store.append(
                packet: packet,
                peripheralID: peripheral,
                characteristicUUID: "FD4B0003",
                frameType: .realtimeHeartRate,
                realtime: WhoopDecodedRealtime(
                    deviceTimestamp: UInt32(deliveredAt.timeIntervalSince1970),
                    heartRate: heartRate,
                    rrIntervals: rrIntervals,
                    source: "whoop5_type40"
                ),
                historical: nil,
                deliveredAt: deliveredAt
            ) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func sleepSnapshot(
        store: WhoopStore,
        now: Date,
        allowAutomaticFinalization: Bool = false
    ) async -> WhoopSleepSnapshot {
        await withCheckedContinuation { continuation in
            store.refreshSleepSnapshot(
                now: now,
                allowAutomaticFinalization: allowAutomaticFinalization
            ) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func dashboardSnapshot(store: WhoopStore) async throws -> DashboardHistorySnapshot {
        let result: Result<DashboardHistorySnapshot, Error> = await withCheckedContinuation {
            continuation in
            store.loadDashboardHistory {
                continuation.resume(returning: $0)
            }
        }
        return try result.get()
    }

    private func scalarInt(_ database: OpaquePointer?, sql: String) -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return -1 }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
        return sqlite3_column_int64(statement, 0)
    }

    private func scalarText(_ database: OpaquePointer?, sql: String) -> String? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let value = sqlite3_column_text(statement, 0)
        else { return nil }
        return String(cString: value)
    }
}
