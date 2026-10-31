import Foundation
import SQLite3

/// A read-only report; it never runs or changes metric derivation.
struct WhoopSleepDiagnosticsBuilder {
    let database: OpaquePointer
    func build(now: Date) throws -> WhoopSleepDiagnostics {
        let iso = ISO8601DateFormatter()
        let audit = try historicalDecodeAudit()
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

        let rows = try WhoopStore.recentHistoricalRows(database: database, now: now)
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
            let bridged = WhoopQuietUpPolicy.bridgedSleepSeconds(
                session: inSession, cadence: sessionCadence)
            let coverage = WhoopStore.observedFraction(of: inSession, cadence: sessionCadence)
            let density = min(1.0, Double(inSession.count) / max(1.0, span / sessionCadence))
            let wake = WhoopStore.elapsedSeconds(across: wakeRows, cadence: sessionCadence)
            let since = latest.timestamp - last.timestamp
            let dateKey = DayKey.string(
                from: Date(timeIntervalSince1970: last.timestamp),
                timeZone: .autoupdatingCurrent
            )
            let stored = try storedSleepID(forDateKey: dateKey, database: database)
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
                bridgedSleepSeconds: bridged,
                sessionCoverage: coverage,
                wakeSeconds: wake
            )
            let storedComplete = try !WhoopStore.shouldDerive(candidate: candidate, database: database)

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
                    spanMinutes: (span / 60).rounded(), durationMinutes: candidate.durationMinutes.rounded(),
                    sampleCount: inSession.count, coverage: coverage, sampleDensity: density,
                    bankedWakeMinutes: (wake / 60).rounded(),
                    minutesSinceLastAsleep: (since / 60).rounded(),
                    passesDurationGate: durationGate, passesCoverageGate: coverageGate,
                    passesWakeCoverageGate: automaticWakeGate,
                    passesWakeElapsedGate: automaticWakeGate,
                    dateKey: dateKey, storedSleepID: stored,
                    storedSummary: try storedRecordSummary(forDateKey: dateKey, database: database),
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
    func historicalDecodeAudit() throws -> (rawTotal: Int?, sampleTotal: Int, outcomes: [String: Int]) {
        // Revision counts are transactional and small; diagnostics never scan
        // the entire archive just to display its size. Raw packet census belongs
        // to the explicit storage audit, not every automatic sleep refresh.
        let rawTotal: Int? = nil
        let sampleTotal = Int(
            try SQLiteRead.requiredInteger(
                database,
                sql: "SELECT COALESCE(SUM(sample_count), 0) FROM whoop_strain_input_revision"))
        let sql = """
            SELECT payload FROM whoop_raw_packet
            WHERE frame_type = \(FrameType.historicalSample.rawValue)
            ORDER BY received_at DESC LIMIT 3000
            """
        let reasons: [String] = try SQLiteRead.rows(database, sql: sql) { statement in
            guard let blob = sqlite3_column_blob(statement, 0) else { return "missing payload" }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))
            return WhoopDecodedHistorical.decodeFailureReason(data)
        }
        let outcomes = reasons.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        return (rawTotal, sampleTotal, outcomes)
    }
    func storedRecordSummary(forDateKey dateKey: String, database: OpaquePointer) throws -> String? {
        let sql = """
            SELECT sleep_score, sleep_duration_minutes, hrv_rmssd_milliseconds,
                   resting_heart_rate_bpm, source
            FROM daily_health_metric WHERE date_key = ? LIMIT 1
            """
        let summaries: [String] = try SQLiteRead.rows(database, sql: sql, bindings: [.text(dateKey)]) { statement in
            let score = sqlite3_column_double(statement, 0)
            let duration = sqlite3_column_double(statement, 1)
            let hrv = sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 2)
            let rhr = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
            let source = textColumn(statement, 4) ?? "?"
            return
                "score \(Int(score.rounded()))% | \(Int(duration.rounded())) min | HRV \(hrv.map { String(Int($0.rounded())) } ?? "nil") | RHR \(rhr.map { String(Int($0.rounded())) } ?? "nil") | \(source)"
        }
        return summaries.first
    }

    func storedSleepID(forDateKey dateKey: String, database: OpaquePointer) throws -> String? {
        guard
            case .value(let value) = try SQLiteRead.text(
                database,
                sql: "SELECT sleep_id FROM daily_health_metric WHERE date_key = ? LIMIT 1", bindings: [.text(dateKey)])
        else { return nil }
        return value
    }

    private func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(statement, index).map { String(cString: $0) }
    }
}
