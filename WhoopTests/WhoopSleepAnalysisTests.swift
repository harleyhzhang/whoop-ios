import SQLite3
import XCTest

@testable import Whoop

extension WhoopSleepStateTests {
    func testSleepStatePreservesUnknownRawValuesWithoutTreatingThemAsWake() {
        let unknown = SleepState(rawValue: 99)
        XCTAssertEqual(unknown, .unknown(99))
        XCTAssertEqual(unknown.rawValue, 99)
        XCTAssertFalse(
            WhoopAutomaticSleepPolicy.canFinalize(
                latestState: unknown,
                secondsSinceLastAsleep: 60 * 60,
                latestSampleIsCurrent: true
            )
        )
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

    func testTonightReturnAfter101MinutesMergesIntoCompletedMorningSleep() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let formatter = ISO8601DateFormatter()
        let firstAsleep = try XCTUnwrap(formatter.date(from: "2026-09-15T05:05:00Z"))
        let lastAsleep = try XCTUnwrap(formatter.date(from: "2026-09-15T10:41:59Z"))
        let resumedAsleep = try XCTUnwrap(formatter.date(from: "2026-09-15T12:23:00Z"))
        let resumedEnd = try XCTUnwrap(formatter.date(from: "2026-09-15T13:21:59Z"))
        var rows: [WhoopStore.HistoricalRow] = []
        for timestamp in stride(
            from: firstAsleep.timeIntervalSince1970,
            through: lastAsleep.timeIntervalSince1970,
            by: 20
        ) {
            rows.append(row(at: timestamp, state: 2))
        }
        rows.append(row(at: lastAsleep.timeIntervalSince1970, state: 2))
        for timestamp in stride(
            from: resumedAsleep.timeIntervalSince1970,
            through: resumedEnd.timeIntervalSince1970,
            by: 20
        ) {
            rows.append(row(at: timestamp, state: 2))
        }
        rows.append(row(at: resumedEnd.timeIntervalSince1970, state: 2))

        let groups = WhoopStore.groupedAsleepRows(rows, timeZone: timeZone)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].first?.timestamp, firstAsleep.timeIntervalSince1970)
        XCTAssertEqual(groups[0].last?.timestamp, resumedEnd.timeIntervalSince1970)
        let duration = WhoopStore.elapsedSeconds(across: groups[0], cadence: 20) / 60
        XCTAssertGreaterThanOrEqual(duration, 396)
        XCTAssertLessThan(duration, 397)
    }

    func testExtendedReopenDoesNotMergeShortSleepOrAfternoonNap() throws {
        let timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let formatter = ISO8601DateFormatter()
        let morningFirst = try XCTUnwrap(formatter.date(from: "2026-09-15T09:00:00Z"))
        let morningLast = try XCTUnwrap(formatter.date(from: "2026-09-15T10:00:00Z"))
        let shortSleepReturn = try XCTUnwrap(formatter.date(from: "2026-09-15T11:41:00Z"))
        XCTAssertFalse(
            WhoopAutomaticSleepPolicy.shouldMergeAsleepRuns(
                firstAsleepTimestamp: morningFirst.timeIntervalSince1970,
                lastAsleepTimestamp: morningLast.timeIntervalSince1970,
                nextAsleepTimestamp: shortSleepReturn.timeIntervalSince1970,
                timeZone: timeZone
            )
        )

        let mainSleepFirst = try XCTUnwrap(formatter.date(from: "2026-09-15T08:00:00Z"))
        let mainSleepLast = try XCTUnwrap(formatter.date(from: "2026-09-15T14:20:00Z"))
        let afternoonNap = try XCTUnwrap(formatter.date(from: "2026-09-15T16:01:00Z"))
        XCTAssertFalse(
            WhoopAutomaticSleepPolicy.shouldMergeAsleepRuns(
                firstAsleepTimestamp: mainSleepFirst.timeIntervalSince1970,
                lastAsleepTimestamp: mainSleepLast.timeIntervalSince1970,
                nextAsleepTimestamp: afternoonNap.timeIntervalSince1970,
                timeZone: timeZone
            )
        )
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

    func testCurrentUpStateStopsReportingSleepImmediately() async throws {
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

        XCTAssertFalse(snapshot.isSleeping)
    }

    func testAutomaticSleepPolicyFinalizesCurrentUpImmediately() {
        XCTAssertFalse(
            WhoopAutomaticSleepPolicy.reportsSleeping(
                latestState: .up,
                latestSampleIsCurrent: true
            )
        )
        XCTAssertTrue(
            WhoopAutomaticSleepPolicy.canFinalize(
                latestState: .up,
                secondsSinceLastAsleep: 0,
                latestSampleIsCurrent: true
            )
        )
        XCTAssertFalse(
            WhoopAutomaticSleepPolicy.canFinalize(
                latestState: .up,
                secondsSinceLastAsleep: 60,
                latestSampleIsCurrent: false
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
        let startedAt = firstWakeCheck.addingTimeInterval(-(4 * 60 * 60 + 60))
        let firstLastAsleep = firstWakeCheck.addingTimeInterval(-60)
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
        let correctedWakeCheck = resumedUntil.addingTimeInterval(60)
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

    func testCompletedHistoricalRRPublishesWithoutLiveBluetoothOvernight() async throws {
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
        let lastAsleep = now.addingTimeInterval(-10 * 60)
        let startedAt = lastAsleep.addingTimeInterval(-(3 * 60 * 60 + 10 * 60))
        let sessionID = try await beginOffload(store: store, peripheral: peripheral)

        for timestamp in stride(
            from: startedAt.timeIntervalSince1970,
            through: lastAsleep.timeIntervalSince1970,
            by: 30
        ) {
            _ = try await append(
                version18Frame(
                    timestamp: UInt32(timestamp),
                    sleepState: 2,
                    rrIntervals: [900, 1_000, 900, 1_000]
                ),
                store: store,
                peripheral: peripheral,
                sessionID: sessionID
            )
        }
        _ = try await append(
            version18Frame(timestamp: UInt32(now.timeIntervalSince1970), sleepState: 0),
            store: store,
            peripheral: peripheral,
            sessionID: sessionID
        )
        _ = try await append(
            metadataFrame(type: 3),
            store: store,
            peripheral: peripheral,
            sessionID: sessionID
        )

        let snapshot = await sleepSnapshot(
            store: store,
            now: now,
            allowAutomaticFinalization: true
        )
        let record = try XCTUnwrap(snapshot.finalizedRecord)

        XCTAssertEqual(record.hrvRMSSDMilliseconds ?? 0, 100, accuracy: 0.001)
        XCTAssertEqual(record.restingHeartRateBPM, 55)
        XCTAssertTrue(record.hasCompletePrimarySleepMetrics)
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
        XCTAssertEqual(features[GeneratedModelFeatures.Sleep.durationIndex], 510)
        XCTAssertEqual(features[GeneratedModelFeatures.Sleep.efficiencyIndex], 97)
        XCTAssertEqual(features[GeneratedModelFeatures.Sleep.lag1DurationIndex], 480)
        XCTAssertEqual(features[GeneratedModelFeatures.Sleep.lag1EfficiencyIndex], 95)
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
            "featureCount": SleepScoreFeatureBuilder.featureCount,
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
}
