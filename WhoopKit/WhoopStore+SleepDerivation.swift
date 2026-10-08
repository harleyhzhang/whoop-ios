import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Nightly record derivation, HRV, and RHR.
extension WhoopStore {
    func derivedRecord(
        for candidate: SleepCandidate,
        now: Date
    ) -> DailyHealthRecord {
        let durationMinutes = candidate.durationMinutes
        let restingHR = restingHeartRate(rows: candidate.asleepRows, cadence: candidate.cadenceSeconds)
        let hrv = nightlyRMSSD(for: candidate)
        let elapsedMinutes = max(
            durationMinutes,
            (candidate.lastSleep.timestamp - candidate.firstSleep.timestamp + candidate.cadenceSeconds) / 60
        )
        let efficiency = min(100, durationMinutes / elapsedMinutes * 100)
        let current = SleepScoreNight(
            dateKey: candidate.dateKey,
            durationMinutes: durationMinutes,
            efficiencyPercentage: efficiency,
            startMinute: Self.minuteOfDay(candidate.startedAt),
            endMinute: Self.minuteOfDay(candidate.endedAt)
        )
        let features = SleepScoreFeatureBuilder.features(
            current: current,
            history: scoreHistory(before: candidate.dateKey)
        )
        let timingAgreement = features.last ?? 100
        let modelPrediction = Self.bundledSleepScoreModel?.prediction(features)
        let sleepScore =
            modelPrediction?.score
            ?? Self.fallbackSleepScore(
                durationMinutes: durationMinutes,
                efficiencyPercentage: efficiency,
                timingAgreementPercentage: timingAgreement
            )
        let iso = ISO8601DateFormatter()
        return DailyHealthRecord(
            dateKey: candidate.dateKey,
            sleepScore: sleepScore,
            sleepDurationMinutes: durationMinutes,
            hrvRMSSDMilliseconds: hrv,
            restingHeartRateBPM: restingHR,
            sleepID: candidate.sleepID,
            cycleID: nil,
            source: Self.localSource,
            sourceArchive: nil,
            sourceUpdatedAt: iso.string(from: now),
            sleepStartAt: iso.string(from: candidate.startedAt),
            sleepEndAt: iso.string(from: candidate.endedAt),
            sleepStartMinute: current.startMinute,
            sleepEndMinute: current.endMinute,
            sleepNeedMinutes: modelPrediction?.sleepNeedMinutes,
            sleepConsistencyPercentage: modelPrediction?.consistencyPercentage
                ?? timingAgreement,
            sleepEfficiencyPercentage: efficiency,
            sleepSufficiencyPercentage: modelPrediction?.sufficiencyPercentage
        )
    }

    func scoreHistory(before dateKey: String) -> [SleepScoreNight] {
        guard let database else { return [] }
        let sql = """
            SELECT date_key, sleep_duration_minutes, sleep_efficiency_percentage,
                   sleep_start_minute, sleep_end_minute
            FROM daily_health_metric
            WHERE date_key < ?
              AND sleep_duration_minutes IS NOT NULL
              AND sleep_efficiency_percentage IS NOT NULL
              AND sleep_start_minute IS NOT NULL
              AND sleep_end_minute IS NOT NULL
            ORDER BY date_key DESC
            LIMIT 10
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(dateKey, to: 1, in: statement)
        var nights: [SleepScoreNight] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let key = textColumn(statement, 0) else { continue }
            nights.append(
                SleepScoreNight(
                    dateKey: key,
                    durationMinutes: sqlite3_column_double(statement, 1),
                    efficiencyPercentage: sqlite3_column_double(statement, 2),
                    startMinute: sqlite3_column_double(statement, 3),
                    endMinute: sqlite3_column_double(statement, 4)
                ))
        }
        return nights
    }

    /// Whether a night still needs deriving. Older local model versions are
    /// always replaced once a coherent offload exists, including when a bug fix
    /// correctly makes a metric smaller. Within one model version, a later
    /// offload remains grow-only so a partial reconstruction cannot shrink a
    /// settled record. Archived WHOOP rows remain authoritative.
    static func shouldDerive(candidate: SleepCandidate, database: OpaquePointer) -> Bool {
        let sql = """
            SELECT source, sleep_score, sleep_duration_minutes,
                   hrv_rmssd_milliseconds, resting_heart_rate_bpm
            FROM daily_health_metric WHERE date_key = ? LIMIT 1
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        _ = candidate.dateKey.withCString { sqlite3_bind_text(statement, 1, $0, -1, transient) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return true }
        guard let source = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
            source.hasPrefix(Self.localSourcePrefix)
        else { return false }
        if source != Self.localSource { return true }
        if (1...4).contains(where: { sqlite3_column_type(statement, Int32($0)) == SQLITE_NULL }) {
            return true
        }
        let existingDuration = sqlite3_column_double(statement, 2)
        return Self.shouldReplaceLocalSleep(
            existingDurationMinutes: existingDuration,
            candidateDurationMinutes: candidate.durationMinutes
        )
    }

    /// A one-minute tolerance avoids rewriting a settled record for harmless
    /// cadence-edge jitter while still repairing any meaningful missing tail.
    static func shouldReplaceLocalSleep(
        existingDurationMinutes: Double,
        candidateDurationMinutes: Double
    ) -> Bool {
        return candidateDurationMinutes > existingDurationMinutes + 1
    }

    /// A completed offload is an explicit, CRC-validated durable session. The
    /// completion sequence must cover every unique historical sample currently
    /// stored; a later partial offload invalidates the proof until it completes.
    static let completedOffloadCoverageQuery = """
        SELECT
            COALESCE((SELECT p.delivery_sequence
             FROM whoop_raw_packet p
             WHERE EXISTS (SELECT 1 FROM whoop_historical_sample h WHERE h.source_packet_id = p.id)
             ORDER BY p.delivery_sequence DESC LIMIT 1), 0),
            (SELECT MAX(completion_sequence)
             FROM whoop_offload_session
             WHERE status = 'complete')
        """
    func completedOffloadCoversLatestHistory(database: OpaquePointer) -> Bool {
        // Walk the delivery index backward to the newest actual history packet.
        // MAX over the joined archive scanned every retained sample per offload.
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, Self.completedOffloadCoverageQuery, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            sqlite3_column_type(statement, 0) != SQLITE_NULL,
            sqlite3_column_type(statement, 1) != SQLITE_NULL
        else { return false }
        let newestSampleSequence = sqlite3_column_int64(statement, 0)
        let newestCompletionSequence = sqlite3_column_int64(statement, 1)
        return newestCompletionSequence >= newestSampleSequence
    }

    /// Lowest five-minute mean heart rate across the night. The minimum sample
    /// requirement is a fraction of what the observed cadence can actually
    /// deliver in five minutes; a fixed count assumed a one-hertz record and so
    /// no window ever qualified, leaving resting heart rate permanently nil.
    func restingHeartRate(rows: [HistoricalRow], cadence: Double) -> Double? {
        guard let start = rows.first?.timestamp, let end = rows.last?.timestamp else { return nil }
        let expectedPerWindow = 5 * 60 / max(cadence, 1)
        let required = max(3, Int((expectedPerWindow * 0.4).rounded()))
        var buckets: [Int: (sum: Double, count: Int)] = [:]
        for row in rows where row.heartRate > 0 && row.timestamp >= start && row.timestamp <= end {
            let bucket = Int((row.timestamp - start) / (5 * 60))
            let current = buckets[bucket] ?? (0, 0)
            buckets[bucket] = (current.sum + Double(row.heartRate), current.count + 1)
        }
        return buckets.values
            .filter { $0.count >= required }
            .map { $0.sum / Double($0.count) }
            .min()
            .map { $0.rounded() }
    }

    /// Prefer the live stream for RMSSD, then fall back to the completed history
    /// offload. iOS can suspend live Bluetooth delivery for an entire night even
    /// though the strap later supplies a dense, timestamped R-R history. Keeping
    /// every historical row as a packet preserves both its boundary and sample
    /// timestamp, so the same continuity and artifact rules apply to both paths.
    func nightlyRMSSD(for candidate: SleepCandidate) -> Double? {
        guard let database else { return nil }
        let standardPackets = realtimeRRPackets(
            database: database,
            from: candidate.firstSleep.timestamp - 30,
            through: candidate.lastSleep.timestamp + 30,
            source: "standard_2a37"
        )
        let ranges = Self.observedAsleepRanges(
            rows: candidate.asleepRows,
            cadence: candidate.cadenceSeconds
        )
        let asleepStandardPackets = standardPackets.filter { packet in
            ranges.contains { packet.timestamp >= $0.lowerBound && packet.timestamp <= $0.upperBound }
        }
        if let value = Self.rmssdFromRealtimePackets(asleepStandardPackets) {
            return value
        }
        let proprietaryPackets = realtimeRRPackets(
            database: database,
            from: candidate.firstSleep.timestamp - 30,
            through: candidate.lastSleep.timestamp + 30,
            source: "whoop5_type40"
        )
        let asleepProprietaryPackets = proprietaryPackets.filter { packet in
            ranges.contains { packet.timestamp >= $0.lowerBound && packet.timestamp <= $0.upperBound }
        }
        if let value = Self.rmssdFromRealtimePackets(asleepProprietaryPackets) {
            return value
        }
        let historicalPackets = historicalRRPackets(
            database: database,
            from: candidate.firstSleep.timestamp - 30,
            through: candidate.lastSleep.timestamp + 30
        )
        let asleepHistoricalPackets = historicalPackets.filter { packet in
            ranges.contains { packet.timestamp >= $0.lowerBound && packet.timestamp <= $0.upperBound }
        }
        return Self.rmssdFromRealtimePackets(asleepHistoricalPackets)
    }

    func realtimeRRPackets(
        database: OpaquePointer,
        from start: TimeInterval,
        through end: TimeInterval,
        source: String
    ) -> [RealtimeRRPacket] {
        let timeColumn = source == "standard_2a37" ? "received_at" : "device_timestamp"
        let sql = """
            SELECT \(timeColumn), rr_intervals_json
            FROM heart_rate_sample
            WHERE source = ?
              AND \(timeColumn) BETWEEN ? AND ?
              AND rr_intervals_json != '[]'
            ORDER BY \(timeColumn), received_at
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        bind(source, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, start)
        sqlite3_bind_double(statement, 3, end)
        var packets: [RealtimeRRPacket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = textColumn(statement, 1) ?? "[]"
            let intervals = (try? JSONDecoder().decode([Double].self, from: Data(text.utf8))) ?? []
            if !intervals.isEmpty {
                packets.append(
                    RealtimeRRPacket(
                        timestamp: sqlite3_column_double(statement, 0),
                        intervals: intervals
                    ))
            }
        }
        return packets
    }

    func historicalRRPackets(
        database: OpaquePointer,
        from start: TimeInterval,
        through end: TimeInterval
    ) -> [RealtimeRRPacket] {
        let sql = """
            SELECT sample_at, rr_intervals_json
            FROM whoop_historical_sample
            WHERE peripheral_id = (
                SELECT peripheral_id FROM whoop_historical_sample
                ORDER BY sample_at DESC LIMIT 1
            )
              AND sample_at BETWEEN ? AND ?
              AND sleep_state = 2
              AND rr_intervals_json != '[]'
            ORDER BY sample_at, ordinal
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, start)
        sqlite3_bind_double(statement, 2, end)
        var packets: [RealtimeRRPacket] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = textColumn(statement, 1) ?? "[]"
            let intervals = (try? JSONDecoder().decode([Double].self, from: Data(text.utf8))) ?? []
            if !intervals.isEmpty {
                packets.append(
                    RealtimeRRPacket(
                        timestamp: sqlite3_column_double(statement, 0),
                        intervals: intervals
                    ))
            }
        }
        return packets
    }
}
