import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Realtime and historical sample rows and sleep candidates.
extension WhoopStore {
    func insertRealtime(
        database: OpaquePointer,
        packetID: String,
        receivedAt: TimeInterval,
        realtime: WhoopDecodedRealtime
    ) -> Bool {
        if realtime.heartRate > 0 {
            let latestSQL = """
                INSERT INTO whoop_latest_heart_rate(singleton, heart_rate, received_at)
                VALUES (1, ?, ?)
                ON CONFLICT(singleton) DO UPDATE SET
                    heart_rate = excluded.heart_rate,
                    received_at = excluded.received_at
                WHERE excluded.received_at >= whoop_latest_heart_rate.received_at
                """
            let latestUpdated =
                withCachedStatement(database: database, sql: latestSQL) { statement in
                    sqlite3_bind_int(statement, 1, Int32(realtime.heartRate))
                    sqlite3_bind_double(statement, 2, receivedAt)
                    return sqlite3_step(statement) == SQLITE_DONE
                } ?? false
            guard latestUpdated else { return false }
        }
        guard !realtime.rrIntervals.isEmpty else { return true }

        let sampleSQL = """
            INSERT INTO heart_rate_sample
            (source_packet_id, received_at, device_timestamp, heart_rate, rr_intervals_json, source)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_packet_id) DO UPDATE SET
                received_at = excluded.received_at,
                device_timestamp = excluded.device_timestamp,
                heart_rate = excluded.heart_rate,
                rr_intervals_json = excluded.rr_intervals_json,
                source = excluded.source
            """
        return withCachedStatement(database: database, sql: sampleSQL) { statement in
            bind(packetID, to: 1, in: statement)
            sqlite3_bind_double(statement, 2, receivedAt)
            if let timestamp = realtime.deviceTimestamp {
                sqlite3_bind_int64(statement, 3, sqlite3_int64(timestamp))
            } else {
                sqlite3_bind_null(statement, 3)
            }
            sqlite3_bind_int(statement, 4, Int32(realtime.heartRate))
            let rrJSON = "[" + realtime.rrIntervals.map(String.init).joined(separator: ",") + "]"
            bind(rrJSON, to: 5, in: statement)
            bind(realtime.source, to: 6, in: statement)
            return sqlite3_step(statement) == SQLITE_DONE
        } ?? false
    }

    func insertHistorical(
        database: OpaquePointer,
        packetID: String,
        sample: WhoopDecodedHistorical
    ) -> Bool {
        let utcOffsetSeconds = nearestRecordedUTCOffset(
            database: database,
            sampleAt: sample.sampleAt
        )
        let stepDateKey = physiologicalStepDateKey(
            for: sample.sampleAt,
            utcOffsetSeconds: utcOffsetSeconds,
            database: database
        )
        let sql = """
            INSERT INTO whoop_historical_sample
            (sample_at, source_packet_id, peripheral_id, protocol_version, ordinal,
             heart_rate, rr_intervals_json, sleep_state, decoder_version,
             step_motion_counter, step_cadence_raw, motion_class_raw,
             step_utc_offset_seconds, step_date_key)
            SELECT ?, ?, p.peripheral_id, COALESCE(p.protocol_version, 18), 0,
                   ?, ?, ?, ?, ?, ?, ?, ?, ?
            FROM whoop_raw_packet p WHERE p.id = ?
            ON CONFLICT(peripheral_id, protocol_version, sample_at, ordinal) DO UPDATE SET
                source_packet_id = excluded.source_packet_id,
                heart_rate = excluded.heart_rate,
                rr_intervals_json = excluded.rr_intervals_json,
                sleep_state = excluded.sleep_state,
                decoder_version = excluded.decoder_version,
                step_motion_counter = excluded.step_motion_counter,
                step_cadence_raw = excluded.step_cadence_raw,
                motion_class_raw = excluded.motion_class_raw,
                step_utc_offset_seconds = excluded.step_utc_offset_seconds,
                step_date_key = excluded.step_date_key
            """
        let succeeded =
            withCachedStatement(database: database, sql: sql) { statement in
                sqlite3_bind_double(statement, 1, sample.sampleAt.timeIntervalSince1970)
                bind(packetID, to: 2, in: statement)
                sqlite3_bind_int(statement, 3, Int32(sample.heartRate))
                let rrJSON = "[" + sample.rrIntervals.map(String.init).joined(separator: ",") + "]"
                bind(rrJSON, to: 4, in: statement)
                sqlite3_bind_int(statement, 5, Int32(sample.sleepState.rawValue))
                sqlite3_bind_int(statement, 6, Int32(Self.decoderVersion))
                sqlite3_bind_int(statement, 7, Int32(sample.stepMotionCounter))
                sqlite3_bind_int(statement, 8, Int32(sample.stepCadenceRaw))
                sqlite3_bind_int(statement, 9, Int32(sample.motionClassRaw))
                sqlite3_bind_int(statement, 10, Int32(utcOffsetSeconds))
                bind(stepDateKey, to: 11, in: statement)
                bind(packetID, to: 12, in: statement)
                return sqlite3_step(statement) == SQLITE_DONE
            } ?? false
        if succeeded { pendingStepDateKeys.insert(stepDateKey) }
        return succeeded
    }

    func backfillHistoricalSamplesIfNeeded() {
        guard let database else { return }
        let count = Int((try? scalarInt(database, sql: "SELECT COUNT(*) FROM whoop_historical_sample")) ?? 0)
        guard count == 0 else { return }
        let sql = """
            SELECT id, payload
            FROM whoop_raw_packet
            WHERE frame_type = \(FrameType.historicalSample.rawValue)
            ORDER BY received_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return }
        defer { sqlite3_finalize(statement) }
        guard execute("BEGIN IMMEDIATE") else { return }
        var succeeded = true
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let packetID = textColumn(statement, 0),
                let payload = dataColumn(statement, 1),
                let historical = WhoopDecodedHistorical.decode(payload)
            else {
                stepResult = sqlite3_step(statement)
                continue
            }
            if !insertHistorical(database: database, packetID: packetID, sample: historical) {
                succeeded = false
                break
            }
            stepResult = sqlite3_step(statement)
        }
        succeeded = succeeded && stepResult == SQLITE_DONE
        if succeeded {
            guard execute("COMMIT") else {
                execute("ROLLBACK")
                return
            }
        } else {
            execute("ROLLBACK")
        }
    }

    struct HistoricalRow {
        let timestamp: TimeInterval
        let heartRate: Int
        let sleepState: SleepState
    }

    struct RealtimeRRPacket: Sendable {
        let timestamp: TimeInterval
        let intervals: [Double]
    }

    struct SleepCandidate {
        let sessionRows: [HistoricalRow]
        let asleepRows: [HistoricalRow]
        let firstSleep: HistoricalRow
        let lastSleep: HistoricalRow
        let latest: HistoricalRow
        let latestSampleIsCurrent: Bool
        /// Observed spacing of the strap's own historical record.
        let cadenceSeconds: Double
        /// The detected sleep interval. A bounded `up` interval followed by
        /// more sleep remains inside the same night; otherwise a false interim
        /// state can shorten a still-running night by an hour.
        let sleepSeconds: Double
        /// Observed samples over samples expected at the observed cadence.
        let sessionCoverage: Double
        /// Elapsed wake time banked after the session ended.
        let wakeSeconds: Double

        var sleepID: String {
            "local-\(Int(firstSleep.timestamp))-\(Int(lastSleep.timestamp))"
        }

        var startedAt: Date { Date(timeIntervalSince1970: firstSleep.timestamp) }
        var endedAt: Date { Date(timeIntervalSince1970: lastSleep.timestamp) }
        var durationMinutes: Double { sleepSeconds / 60.0 }
        var dateKey: String { DayKey.string(from: endedAt, timeZone: .autoupdatingCurrent) }
        var secondsSinceLastAsleep: Double { latest.timestamp - lastSleep.timestamp }

        /// Evidence gates decide whether the night can be honestly scored at all.
        var meetsEvidenceGates: Bool {
            sleepSeconds >= WhoopAutomaticSleepPolicy.primarySleepMinimum
                && sessionCoverage >= 0.50
        }

        /// Explicit awake and a current `up` sample can finalize immediately.
        /// An `up` result remains provisional and reversible if sleep resumes.
        var meetsAutomaticWakeGate: Bool {
            WhoopAutomaticSleepPolicy.canFinalize(
                latestState: latest.sleepState,
                secondsSinceLastAsleep: secondsSinceLastAsleep,
                latestSampleIsCurrent: latestSampleIsCurrent
            )
        }

    }

    /// The strap's historical record is not one hertz. It stores roughly one
    /// distinct sample every six seconds, so every duration and coverage figure
    /// is derived from the observed cadence rather than from counting seconds
    /// that happen to carry a sample. Counting seconds made a full night look
    /// like minutes and put both evidence gates permanently out of reach.
    static func cadenceSeconds(of rows: [HistoricalRow]) -> Double {
        guard rows.count > 1 else { return 6 }
        var gaps: [Double] = []
        for index in 1..<rows.count {
            let delta = rows[index].timestamp - rows[index - 1].timestamp
            if delta > 0, delta <= 300 { gaps.append(delta) }
        }
        guard !gaps.isEmpty else { return 6 }
        gaps.sort()
        return min(max(gaps[gaps.count / 2], 1), 60)
    }

    /// Fraction of a session the strap actually gave evidence for. Only gaps
    /// longer than the outage cap count against it, which is the same cap the
    /// duration integration refuses to count as sleep, so the two agree.
    /// Sampling density is deliberately excluded: a night recorded every sixteen
    /// seconds instead of every six is still a fully observed night, and gating
    /// on density rejected good nights for a property that does not threaten
    /// the duration estimate.
    static func observedFraction(of rows: [HistoricalRow], cadence: Double) -> Double {
        guard rows.count > 1, let first = rows.first, let last = rows.last else { return 0 }
        let span = max(1.0, last.timestamp - first.timestamp)
        let cap = max(cadence * 4, 120.0)
        var unobserved = 0.0
        for index in 1..<rows.count {
            let delta = rows[index].timestamp - rows[index - 1].timestamp
            if delta > cap { unobserved += delta - cadence }
        }
        return max(0.0, min(1.0, (span - unobserved) / span))
    }

    /// Elapsed time represented by a run of samples. A gap longer than the
    /// outage cap contributes one sample of time rather than the whole gap, so
    /// neither a dropout nor a long awakening is ever counted as sleep.
    static func elapsedSeconds(across rows: [HistoricalRow], cadence: Double) -> Double {
        guard !rows.isEmpty else { return 0 }
        guard rows.count > 1 else { return cadence }
        let cap = max(cadence * 4, 120.0)
        var total = cadence
        for index in 1..<rows.count {
            let delta = rows[index].timestamp - rows[index - 1].timestamp
            total += delta <= cap ? delta : cadence
        }
        return total
    }

    enum SleepAnalysis {
        case noData
        case sleeping(Date, SleepCandidate?)
        /// Every main sleep in the window, oldest first. All of them are
        /// considered, not only the most recent: a night that ends while the app
        /// is never opened would otherwise be skipped permanently, because the
        /// strap trims its history once a chunk is acknowledged.
        case awake(Date, [SleepCandidate])
    }

    /// Detects the latest main sleep without storing anything. Keeping detection
    /// separate from finalization lets automatic timing and evidence gates decide
    /// when a coherent night is ready to publish.
    /// The 48-hour window every sleep decision is made from.
    func recentHistoricalRows(now: Date) -> [HistoricalRow] {
        guard let database else { return [] }
        return Self.recentHistoricalRows(database: database, now: now)
    }

    static func recentHistoricalRows(database: OpaquePointer, now: Date) -> [HistoricalRow] {
        let cutoff = now.addingTimeInterval(-48 * 60 * 60).timeIntervalSince1970
        let sql = """
            SELECT sample_at, heart_rate, sleep_state
            FROM whoop_historical_sample
            WHERE sample_at >= ?
              AND peripheral_id = (
                  \(WhoopStrainInputIndex.latestPeripheralQuery)
              )
            ORDER BY sample_at ASC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)

        var rows: [HistoricalRow] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                HistoricalRow(
                    timestamp: sqlite3_column_double(statement, 0),
                    heartRate: Int(sqlite3_column_int(statement, 1)),
                    sleepState: SleepState(rawValue: Int(sqlite3_column_int(statement, 2)))
                ))
        }
        return rows
    }
}
