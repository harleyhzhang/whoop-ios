import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Sleep diagnostics and decode audits.
extension WhoopStore {
    /// Writes the diagnostics beside the database as JSON. Small and overwritten
    /// each time, so it can be pulled off the device when the dashboard shows
    /// nothing and the reason is not obvious.
    func writeSleepDiagnostics(now: Date = .now) {
        queue.async { [self] in
            let diagnostics = buildSleepDiagnostics(now: now)
            guard let directory = Self.databaseDirectory() else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(diagnostics) else { return }
            try? data.write(
                to: directory.appendingPathComponent("sleep-diagnostics.json"),
                options: .atomic
            )
        }
    }

    func buildSleepDiagnostics(now: Date) -> WhoopSleepDiagnostics {
        let iso = ISO8601DateFormatter()
        let audit = historicalDecodeAudit()
        func stamp(_ interval: TimeInterval) -> String {
            iso.string(from: Date(timeIntervalSince1970: interval))
        }
        func shell(_ outcome: String, rows: [HistoricalRow] = []) -> WhoopSleepDiagnostics {
            var histogram: [String: Int] = [:]
            for row in rows { histogram["\(row.sleepState.rawValue)", default: 0] += 1 }
            return WhoopSleepDiagnostics(
                generatedAt: iso.string(from: now), windowHours: 48,
                sampleCount: rows.count,
                firstSampleAt: rows.first.map { stamp($0.timestamp) },
                lastSampleAt: rows.last.map { stamp($0.timestamp) },
                secondsSinceLastSample: rows.last.map { Int(now.timeIntervalSince1970 - $0.timestamp) },
                observedCadenceSeconds: rows.isEmpty ? nil : Self.cadenceSeconds(of: rows),
                largestGapSeconds: nil, sleepStateHistogram: histogram,
                rawType47PacketTotal: audit.rawTotal,
                historicalSampleTotal: audit.sampleTotal,
                recentType47Outcomes: audit.outcomes,
                sessions: [], outcome: outcome
            )
        }

        guard let database else { return shell("no database") }
        let rows = recentHistoricalRows(now: now)
        guard !rows.isEmpty else { return shell("no historical samples in the last 48 hours") }

        var histogram: [String: Int] = [:]
        for row in rows { histogram["\(row.sleepState.rawValue)", default: 0] += 1 }
        let cadence = Self.cadenceSeconds(of: rows)
        var largestGap = 0.0
        for index in 1..<rows.count {
            largestGap = max(largestGap, rows[index].timestamp - rows[index - 1].timestamp)
        }

        let asleepRows = rows.filter { $0.sleepState == .asleep }
        let groups = Self.groupedAsleepRows(asleepRows)

        let latest = rows[rows.count - 1]
        var sessions: [WhoopSleepSessionDiagnostics] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let span = max(1.0, last.timestamp - first.timestamp)
            let inSession = rows.filter { $0.timestamp >= first.timestamp && $0.timestamp <= last.timestamp }
            let sessionCadence = Self.cadenceSeconds(of: inSession)
            let wakeRows = rows.filter { $0.timestamp > last.timestamp && $0.sleepState != .asleep }
            let duration = Self.elapsedSeconds(across: group, cadence: sessionCadence)
            let coverage = Self.observedFraction(of: inSession, cadence: sessionCadence)
            let density = min(1.0, Double(inSession.count) / max(1.0, span / sessionCadence))
            let wake = Self.elapsedSeconds(across: wakeRows, cadence: sessionCadence)
            let since = latest.timestamp - last.timestamp
            let dateKey = DayKey.string(
                from: Date(timeIntervalSince1970: last.timestamp),
                timeZone: .autoupdatingCurrent
            )
            let stored = storedSleepID(forDateKey: dateKey, database: database)
            let durationGate = duration >= WhoopAutomaticSleepPolicy.primarySleepMinimum
            let coverageGate = coverage >= 0.50
            let latestSampleIsCurrent = abs(now.timeIntervalSince1970 - latest.timestamp) <= 30 * 60
            let automaticWakeGate = WhoopAutomaticSleepPolicy.canFinalize(
                latestState: latest.sleepState,
                secondsSinceLastAsleep: since,
                latestSampleIsCurrent: latestSampleIsCurrent
            )

            let candidate = SleepCandidate(
                sessionRows: inSession,
                asleepRows: group,
                firstSleep: first,
                lastSleep: last,
                latest: latest,
                latestSampleIsCurrent: latestSampleIsCurrent,
                cadenceSeconds: sessionCadence,
                sleepSeconds: duration,
                sessionCoverage: coverage,
                wakeSeconds: wake
            )
            let storedComplete = !shouldDerive(candidate: candidate, database: database)
            let metricsComplete = derivedRecord(for: candidate, now: now).hasCompletePrimarySleepMetrics

            let verdict: String
            if storedComplete {
                verdict = "already stored"
            } else if !durationGate || !coverageGate {
                verdict = "pending; evidence incomplete"
            } else if !metricsComplete {
                verdict = "pending; primary metrics still loading"
            } else if !automaticWakeGate {
                verdict = "pending; automatic wake delay"
            } else {
                verdict = "all gates pass; finalizes automatically"
            }

            sessions.append(
                WhoopSleepSessionDiagnostics(
                    startedAt: stamp(first.timestamp), endedAt: stamp(last.timestamp),
                    spanMinutes: (span / 60).rounded(), durationMinutes: (duration / 60).rounded(),
                    sampleCount: inSession.count, coverage: coverage, sampleDensity: density,
                    bankedWakeMinutes: (wake / 60).rounded(),
                    minutesSinceLastAsleep: (since / 60).rounded(),
                    passesDurationGate: durationGate, passesCoverageGate: coverageGate,
                    passesWakeCoverageGate: automaticWakeGate,
                    passesWakeElapsedGate: automaticWakeGate,
                    dateKey: dateKey, storedSleepID: stored,
                    storedSummary: storedRecordSummary(forDateKey: dateKey, database: database),
                    verdict: verdict
                ))
        }

        return WhoopSleepDiagnostics(
            generatedAt: iso.string(from: now), windowHours: 48,
            sampleCount: rows.count,
            firstSampleAt: stamp(rows[0].timestamp),
            lastSampleAt: stamp(latest.timestamp),
            secondsSinceLastSample: Int(now.timeIntervalSince1970 - latest.timestamp),
            observedCadenceSeconds: cadence, largestGapSeconds: Int(largestGap),
            sleepStateHistogram: histogram,
            rawType47PacketTotal: audit.rawTotal,
            historicalSampleTotal: audit.sampleTotal,
            recentType47Outcomes: audit.outcomes,
            sessions: sessions,
            outcome: sessions.last?.verdict ?? "no sample carried sleep_state 2 in the last 48 hours"
        )
    }

    /// Compares stored type-47 packets against the samples they produced. A ratio
    /// near one means the strap itself reports sparsely; a large ratio means this
    /// app is discarding frames it already acknowledged and cannot re-request.
    func historicalDecodeAudit() -> (rawTotal: Int, sampleTotal: Int, outcomes: [String: Int]) {
        guard let database else { return (0, 0, [:]) }
        // Successful derived rows and the sparse failure ledger together have
        // the indexed shape diagnostics need. Counting the raw table forced a
        // full scan of more than a million retained frames.
        let rawTotal = Int(
            (try? scalarInt(
                database,
                sql: """
                    SELECT
                        (SELECT COUNT(*) FROM whoop_historical_sample
                         WHERE decoder_version = \(Self.decoderVersion))
                      + (SELECT COUNT(*) FROM whoop_ppg_packet
                         WHERE decoder_version = \(Self.decoderVersion))
                      + (SELECT COUNT(*) FROM whoop_decode_failure
                         WHERE decoder_version = \(Self.decoderVersion))
                    """
            )) ?? 0)
        let sampleTotal = Int((try? scalarInt(database, sql: "SELECT COUNT(*) FROM whoop_historical_sample")) ?? 0)
        var outcomes: [String: Int] = [:]
        let sql = """
            SELECT payload FROM whoop_raw_packet
            WHERE frame_type = \(FrameType.historicalSample.rawValue)
            ORDER BY received_at DESC
            LIMIT 3000
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return (rawTotal, sampleTotal, outcomes) }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(statement, 0) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
            outcomes[WhoopDecodedHistorical.decodeFailureReason(data), default: 0] += 1
        }
        return (rawTotal, sampleTotal, outcomes)
    }
}
