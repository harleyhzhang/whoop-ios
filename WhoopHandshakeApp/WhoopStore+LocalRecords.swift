import CryptoKit
import Foundation
import OSLog
import SQLite3

/// R-R statistics and locally derived daily records.
extension WhoopStore {
    static func observedAsleepRanges(
        rows: [HistoricalRow],
        cadence: Double
    ) -> [ClosedRange<TimeInterval>] {
        guard let first = rows.first else { return [] }
        let maximumGap = max(cadence * 4, 120)
        var ranges: [ClosedRange<TimeInterval>] = []
        var start = first.timestamp
        var previous = first.timestamp
        for row in rows.dropFirst() {
            if row.timestamp - previous > maximumGap {
                ranges.append((start - cadence)...(previous + cadence))
                start = row.timestamp
            }
            previous = row.timestamp
        }
        ranges.append((start - cadence)...(previous + cadence))
        return ranges
    }

    /// Computes artifact-filtered five-minute RMSSD windows while allowing
    /// continuity only inside one packet or across packets delivered no more
    /// than three seconds apart. An interval more than 20% from that window's
    /// median breaks the chain rather than stitching its neighbours together.
    /// The nightly median prevents a few motion-heavy windows from dominating
    /// the result. Returning nil is preferable to false precision.
    static func rmssdFromRealtimePackets(
        _ packets: [RealtimeRRPacket],
        minimumDifferencesPerWindow: Int = 20
    ) -> Double? {
        guard !packets.isEmpty else { return nil }
        let alreadyOrdered = zip(packets, packets.dropFirst()).allSatisfy {
            $0.timestamp <= $1.timestamp
        }
        let ordered =
            alreadyOrdered
            ? packets
            : packets.sorted { lhs, rhs in
                lhs.timestamp == rhs.timestamp
                    ? lhs.intervals.count < rhs.intervals.count
                    : lhs.timestamp < rhs.timestamp
            }
        let windows = Dictionary(grouping: ordered) { Int($0.timestamp / 300) }
        var values: [Double] = []
        for packets in windows.values {
            let plausible =
                packets
                .flatMap(\.intervals)
                .filter { (300...2_000).contains($0) }
                .sorted()
            guard !plausible.isEmpty else { continue }
            let middle = plausible.count / 2
            let median =
                plausible.count.isMultiple(of: 2)
                ? (plausible[middle - 1] + plausible[middle]) / 2
                : plausible[middle]
            var squares: [Double] = []
            var previousInterval: Double?
            var previousPacketTimestamp: TimeInterval?
            var previousWasValid = false
            for packet in packets {
                let packetGap = previousPacketTimestamp.map { packet.timestamp - $0 }
                for (index, interval) in packet.intervals.enumerated() {
                    let valid =
                        (300...2_000).contains(interval)
                        && median > 0
                        && abs(interval - median) / median <= 0.20
                    let adjacent =
                        index > 0
                        || packetGap.map { $0 > 0 && $0 <= 3 } == true
                    if valid, previousWasValid, adjacent, let previousInterval {
                        let difference = interval - previousInterval
                        squares.append(difference * difference)
                    }
                    previousInterval = valid ? interval : nil
                    previousWasValid = valid
                }
                previousPacketTimestamp = packet.timestamp
            }
            if squares.count >= minimumDifferencesPerWindow {
                values.append(sqrt(squares.reduce(0, +) / Double(squares.count)))
            }
        }
        guard !values.isEmpty else { return nil }
        values.sort()
        let middle = values.count / 2
        return values.count.isMultiple(of: 2)
            ? (values[middle - 1] + values[middle]) / 2
            : values[middle]
    }

    /// Versioned so a change to any derivation re-derives the nights written by
    /// the previous version instead of leaving stale values in the history.
    /// Anything with the `whoop5_local` prefix is ours; anything else is an
    /// archived WHOOP row and is authoritative.
    static let bundledSleepScoreModel = SleepScoreModelBundle.load()
    static let bundledRecoveryScoreModel = RecoveryScoreModelBundle.load()
    static let localSource = "\(bundledSleepScoreModel?.version ?? "whoop5_local_v5_fallback")_materialized_4"
    static let localSourcePrefix = "whoop5_local"

    /// A deterministic, coefficient-only safety net for development builds
    /// without Harley's private model bundle. The production private bundle is
    /// an Extra Trees + RBF-SVR ensemble and replaces this automatically.
    static func fallbackSleepScore(
        durationMinutes: Double,
        efficiencyPercentage: Double,
        timingAgreementPercentage: Double
    ) -> Double {
        min(
            99,
            max(
                0,
                -101.418011
                    + 0.10204614 * durationMinutes
                    + 0.43013477 * efficiencyPercentage
                    + 1.06691453 * timingAgreementPercentage
            ))
    }

    static func minuteOfDay(_ date: Date) -> Double {
        let components = Calendar.autoupdatingCurrent.dateComponents(
            [.hour, .minute, .second, .nanosecond], from: date
        )
        return Double(components.hour ?? 0) * 60
            + Double(components.minute ?? 0)
            + Double(components.second ?? 0) / 60
            + Double(components.nanosecond ?? 0) / 60_000_000_000
    }

    func upsertLocalDailyHealthRecord(
        _ record: DailyHealthRecord,
        database: OpaquePointer
    ) -> Bool {
        let previousWakeAt = storedWakeAt(dateKey: record.dateKey, database: database)
        let sql = """
            INSERT INTO daily_health_metric
            (date_key, sleep_score, sleep_duration_minutes, hrv_rmssd_milliseconds,
             resting_heart_rate_bpm, sleep_id, cycle_id, source, source_archive,
             source_updated_at, imported_at, sleep_start_at, sleep_end_at,
             sleep_start_minute, sleep_end_minute, sleep_need_minutes,
             sleep_consistency_percentage, sleep_efficiency_percentage,
             sleep_sufficiency_percentage)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                sleep_score = excluded.sleep_score,
                sleep_duration_minutes = excluded.sleep_duration_minutes,
                hrv_rmssd_milliseconds = excluded.hrv_rmssd_milliseconds,
                resting_heart_rate_bpm = excluded.resting_heart_rate_bpm,
                sleep_id = excluded.sleep_id,
                cycle_id = excluded.cycle_id,
                source = excluded.source,
                source_archive = excluded.source_archive,
                source_updated_at = excluded.source_updated_at,
                imported_at = excluded.imported_at,
                sleep_start_at = excluded.sleep_start_at,
                sleep_end_at = excluded.sleep_end_at,
                sleep_start_minute = excluded.sleep_start_minute,
                sleep_end_minute = excluded.sleep_end_minute,
                sleep_need_minutes = excluded.sleep_need_minutes,
                sleep_consistency_percentage = excluded.sleep_consistency_percentage,
                sleep_efficiency_percentage = excluded.sleep_efficiency_percentage,
                sleep_sufficiency_percentage = excluded.sleep_sufficiency_percentage
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        bind(record.dateKey, to: 1, in: statement)
        bind(record.sleepScore, to: 2, in: statement)
        bind(record.sleepDurationMinutes, to: 3, in: statement)
        bind(record.hrvRMSSDMilliseconds, to: 4, in: statement)
        bind(record.restingHeartRateBPM, to: 5, in: statement)
        bind(record.sleepID, to: 6, in: statement)
        bind(record.cycleID, to: 7, in: statement)
        bind(record.source, to: 8, in: statement)
        bind(record.sourceArchive, to: 9, in: statement)
        bind(record.sourceUpdatedAt, to: 10, in: statement)
        sqlite3_bind_double(statement, 11, Date().timeIntervalSince1970)
        bind(record.sleepStartAt, to: 12, in: statement)
        bind(record.sleepEndAt, to: 13, in: statement)
        bind(record.sleepStartMinute, to: 14, in: statement)
        bind(record.sleepEndMinute, to: 15, in: statement)
        bind(record.sleepNeedMinutes, to: 16, in: statement)
        bind(record.sleepConsistencyPercentage, to: 17, in: statement)
        bind(record.sleepEfficiencyPercentage, to: 18, in: statement)
        bind(record.sleepSufficiencyPercentage, to: 19, in: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        cachedPublishedWakeBoundaries = nil
        return assignStepsToPublishedDay(
            record,
            replacingWakeAt: previousWakeAt,
            database: database
        )
    }

    func storedWakeAt(dateKey: String, database: OpaquePointer) -> Date? {
        let sql = "SELECT sleep_end_at FROM daily_health_metric WHERE date_key = ? LIMIT 1"
        return withCachedStatement(database: database, sql: sql) { statement in
            bind(dateKey, to: 1, in: statement)
            guard sqlite3_step(statement) == SQLITE_ROW,
                let raw = textColumn(statement, 0)
            else { return nil }
            return Self.parseISO8601(raw)
        } ?? nil
    }

    /// Score-model backfills must not erase a previously valid HRV or RHR if
    /// the old realtime R-R window is no longer available to recompute it.
    func updateLocalSleepScore(
        _ record: DailyHealthRecord,
        database: OpaquePointer
    ) -> Bool {
        let sql = """
            UPDATE daily_health_metric
            SET sleep_score = ?, source = ?, source_updated_at = ?, imported_at = ?,
                sleep_start_at = ?, sleep_end_at = ?, sleep_start_minute = ?,
                sleep_end_minute = ?, sleep_consistency_percentage = ?,
                sleep_efficiency_percentage = ?, sleep_need_minutes = ?,
                sleep_sufficiency_percentage = ?
            WHERE date_key = ? AND source LIKE 'whoop5_local%'
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        bind(record.sleepScore, to: 1, in: statement)
        bind(record.source, to: 2, in: statement)
        bind(record.sourceUpdatedAt, to: 3, in: statement)
        sqlite3_bind_double(statement, 4, Date().timeIntervalSince1970)
        bind(record.sleepStartAt, to: 5, in: statement)
        bind(record.sleepEndAt, to: 6, in: statement)
        bind(record.sleepStartMinute, to: 7, in: statement)
        bind(record.sleepEndMinute, to: 8, in: statement)
        bind(record.sleepConsistencyPercentage, to: 9, in: statement)
        bind(record.sleepEfficiencyPercentage, to: 10, in: statement)
        bind(record.sleepNeedMinutes, to: 11, in: statement)
        bind(record.sleepSufficiencyPercentage, to: 12, in: statement)
        bind(record.dateKey, to: 13, in: statement)
        let succeeded = sqlite3_step(statement) == SQLITE_DONE
        if succeeded { cachedPublishedWakeBoundaries = nil }
        return succeeded
    }
}
