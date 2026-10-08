import Foundation
import SQLite3

/// A read-only report; it never runs or changes metric derivation.
struct WhoopSleepDiagnosticsBuilder {
    let database: OpaquePointer
    func build(now: Date) -> WhoopSleepDiagnostics {
        let iso = ISO8601DateFormatter()
        let audit = historicalDecodeAudit()
        func stamp(_ interval: TimeInterval) -> String {
            iso.string(from: Date(timeIntervalSince1970: interval))
        }
        func shell(_ outcome: String, rows: [WhoopStore.HistoricalRow] = []) -> WhoopSleepDiagnostics {
            var histogram: [String: Int] = [:]
            for row in rows { histogram["\(row.sleepState.rawValue)", default: 0] += 1 }
            return WhoopSleepDiagnostics(
                generatedAt: iso.string(from: now), windowHours: 48,
                sampleCount: rows.count,
                firstSampleAt: rows.first.map { stamp($0.timestamp) },
                lastSampleAt: rows.last.map { stamp($0.timestamp) },
                secondsSinceLastSample: rows.last.map { Int(now.timeIntervalSince1970 - $0.timestamp) },
                observedCadenceSeconds: rows.isEmpty ? nil : WhoopStore.cadenceSeconds(of: rows),
                largestGapSeconds: nil, sleepStateHistogram: histogram,
                rawType47PacketTotal: audit.rawTotal,
                historicalSampleTotal: audit.sampleTotal,
                recentType47Outcomes: audit.outcomes,
                sessions: [], outcome: outcome
            )
        }

        let rows = WhoopStore.recentHistoricalRows(database: database, now: now)
        guard !rows.isEmpty else { return shell("no historical samples in the last 48 hours") }

        var histogram: [String: Int] = [:]
        for row in rows { histogram["\(row.sleepState.rawValue)", default: 0] += 1 }
        let cadence = WhoopStore.cadenceSeconds(of: rows)
        var largestGap = 0.0
        for index in 1..<rows.count {
            largestGap = max(largestGap, rows[index].timestamp - rows[index - 1].timestamp)
        }

        let asleepRows = rows.filter { $0.sleepState == .asleep }
        let groups = WhoopStore.groupedAsleepRows(asleepRows)

        let latest = rows[rows.count - 1]
        var sessions: [WhoopSleepSessionDiagnostics] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let span = max(1.0, last.timestamp - first.timestamp)
            let inSession = rows.filter { $0.timestamp >= first.timestamp && $0.timestamp <= last.timestamp }
            let sessionCadence = WhoopStore.cadenceSeconds(of: inSession)
            let wakeRows = rows.filter { $0.timestamp > last.timestamp && $0.sleepState != .asleep }
            let duration = WhoopStore.elapsedSeconds(across: group, cadence: sessionCadence)
            let coverage = WhoopStore.observedFraction(of: inSession, cadence: sessionCadence)
            let density = min(1.0, Double(inSession.count) / max(1.0, span / sessionCadence))
            let wake = WhoopStore.elapsedSeconds(across: wakeRows, cadence: sessionCadence)
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

            let candidate = WhoopStore.SleepCandidate(
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
            let storedComplete = !WhoopStore.shouldDerive(candidate: candidate, database: database)

            let verdict: String
            if storedComplete {
                verdict = "already stored"
            } else if !durationGate || !coverageGate {
                verdict = "pending; evidence incomplete"
            } else if !automaticWakeGate {
                verdict = "pending; automatic wake delay"
            } else {
                verdict = "pending; automatic metric evaluation"
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

    /// Bounded recent decode outcomes plus a transactional sample count. Full
    /// retained-packet census is intentionally excluded from automatic reports.
    func historicalDecodeAudit() -> (rawTotal: Int?, sampleTotal: Int, outcomes: [String: Int]) {
        // Revision counts are transactional and small; diagnostics never scan
        // the entire archive just to display its size. Raw packet census belongs
        // to the explicit storage audit, not every automatic sleep refresh.
        let rawTotal: Int? = nil
        let sampleTotal = Int(
            (try? scalarInt(
                database,
                sql: "SELECT COALESCE(SUM(sample_count), 0) FROM whoop_strain_input_revision")) ?? 0)
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
    func storedRecordSummary(forDateKey dateKey: String, database: OpaquePointer) -> String? {
        let sql = """
            SELECT sleep_score, sleep_duration_minutes, hrv_rmssd_milliseconds,
                   resting_heart_rate_bpm, source
            FROM daily_health_metric WHERE date_key = ? LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(dateKey, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let score = sqlite3_column_double(statement, 0)
        let duration = sqlite3_column_double(statement, 1)
        let hrv = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)
        let rhr = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
        let source = textColumn(statement, 4) ?? "?"
        return
            "score \(Int(score.rounded()))% | \(Int(duration.rounded())) min | HRV \(hrv.map { String(Int($0.rounded())) } ?? "nil") | RHR \(rhr.map { String(Int($0.rounded())) } ?? "nil") | \(source)"
    }

    func storedSleepID(forDateKey dateKey: String, database: OpaquePointer) -> String? {
        let sql = "SELECT sleep_id FROM daily_health_metric WHERE date_key = ? LIMIT 1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return nil }
        defer { sqlite3_finalize(statement) }
        bind(dateKey, to: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return textColumn(statement, 0)
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, WhoopStore.transient) }
    }
    private func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }
    private func scalarInt(_ database: OpaquePointer, sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DashboardRepository.QueryError.failed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DashboardRepository.QueryError.failed(String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }
}
