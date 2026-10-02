import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Bundled history, official metrics, and archive import.
extension WhoopStore {
    func importBundledHistory() {
        guard let database,
            let url = Bundle.main.url(forResource: "whoop-history", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let records = try? JSONDecoder().decode([DailyHealthRecord].self, from: data)
        else { return }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard metadataValue(database: database, key: "bundled-history-sha256") != digest else {
            return
        }
        guard execute("BEGIN IMMEDIATE") else { return }
        for record in records where !upsertDailyHealthRecord(record, database: database) {
            execute("ROLLBACK")
            return
        }
        guard
            setMetadataValue(
                database: database,
                key: "bundled-history-sha256",
                value: digest
            )
        else {
            execute("ROLLBACK")
            return
        }
        guard execute("COMMIT") else {
            execute("ROLLBACK")
            return
        }
    }

    /// Imports only the stable daily projection into the hot database while
    /// installing a compact, checksum-verified sidecar containing every exact
    /// official-app response. This keeps launch queries small without throwing
    /// away fields that a future model may need.
    func importBundledOfficialMetrics() {
        guard let database,
            let metricsURL = Bundle.main.url(
                forResource: "whoop-official-metrics", withExtension: "json"
            ),
            let metricsData = try? Data(contentsOf: metricsURL),
            let seed = try? JSONDecoder().decode(OfficialMetricsSeed.self, from: metricsData),
            seed.formatVersion == 1
        else { return }
        let digest = SHA256.hash(data: metricsData).map { String(format: "%02x", $0) }.joined()
        if metadataValue(database: database, key: "bundled-official-metrics-sha256") == digest {
            if let directory = Self.databaseDirectory(),
                !FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent("whoop-official-archive.sqlite3").path
                )
            {
                _ = installBundledOfficialArchive(expectedSHA256: seed.sourceDatabaseSHA256)
            }
            return
        }
        guard installBundledOfficialArchive(expectedSHA256: seed.sourceDatabaseSHA256) else {
            Self.logger.error("Refusing official metric import because its complete raw sidecar is unavailable")
            return
        }
        guard execute("BEGIN IMMEDIATE") else { return }
        for record in seed.daily
        where !upsertOfficialDailyMetric(
            record,
            sourceArchive: seed.sourceArchive,
            sourceManifestSHA256: seed.sourceManifestSHA256,
            database: database
        ) {
            execute("ROLLBACK")
            return
        }
        guard
            setMetadataValue(
                database: database,
                key: "bundled-official-metrics-sha256",
                value: digest
            ),
            setMetadataValue(
                database: database,
                key: "bundled-official-archive-sha256",
                value: seed.sourceDatabaseSHA256
            )
        else {
            execute("ROLLBACK")
            return
        }
        guard execute("COMMIT") else {
            execute("ROLLBACK")
            return
        }
    }

    func installBundledOfficialArchive(expectedSHA256: String) -> Bool {
        guard
            let source = Bundle.main.url(
                forResource: "whoop-official-archive", withExtension: "sqlite3"
            ), let directory = Self.databaseDirectory()
        else { return false }
        let destination = directory.appendingPathComponent("whoop-official-archive.sqlite3")
        let fileManager = FileManager.default

        func fileDigest(_ url: URL) -> String? {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        if fileManager.fileExists(atPath: destination.path),
            fileDigest(destination) == expectedSHA256
        {
            return true
        }

        let temporary = directory.appendingPathComponent(".whoop-official-archive-installing.sqlite3")
        try? fileManager.removeItem(at: temporary)
        do {
            try fileManager.copyItem(at: source, to: temporary)
            guard fileDigest(temporary) == expectedSHA256 else {
                try? fileManager.removeItem(at: temporary)
                return false
            }
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path
            )
            return true
        } catch {
            try? fileManager.removeItem(at: temporary)
            Self.logger.error(
                "Could not install official response archive: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func upsertOfficialDailyMetric(
        _ record: OfficialDailyMetricSeed,
        sourceArchive: String,
        sourceManifestSHA256: String,
        database: OpaquePointer
    ) -> Bool {
        guard DayKey(rawValue: record.dateKey) != nil else { return false }
        let sql = """
            INSERT INTO whoop_official_daily_metric
            (date_key, official_recovery_score, official_steps, official_day_strain,
             day_strain_target, steps_baseline, hrv, hrv_baseline, rhr, rhr_baseline,
             respiratory_rate, respiratory_rate_baseline, sleep_performance,
             sleep_performance_baseline, source_recovery_sha256, source_strain_sha256,
             source_archive, source_manifest_sha256, imported_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                official_recovery_score = excluded.official_recovery_score,
                official_steps = excluded.official_steps,
                official_day_strain = excluded.official_day_strain,
                day_strain_target = excluded.day_strain_target,
                steps_baseline = excluded.steps_baseline,
                hrv = excluded.hrv, hrv_baseline = excluded.hrv_baseline,
                rhr = excluded.rhr, rhr_baseline = excluded.rhr_baseline,
                respiratory_rate = excluded.respiratory_rate,
                respiratory_rate_baseline = excluded.respiratory_rate_baseline,
                sleep_performance = excluded.sleep_performance,
                sleep_performance_baseline = excluded.sleep_performance_baseline,
                source_recovery_sha256 = excluded.source_recovery_sha256,
                source_strain_sha256 = excluded.source_strain_sha256,
                source_archive = excluded.source_archive,
                source_manifest_sha256 = excluded.source_manifest_sha256,
                imported_at = excluded.imported_at
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        bind(record.dateKey, to: 1, in: statement)
        bind(record.officialRecoveryScore, to: 2, in: statement)
        bind(record.officialSteps.map(Int64.init), to: 3, in: statement)
        bind(record.officialDayStrain, to: 4, in: statement)
        bind(record.dayStrainTarget, to: 5, in: statement)
        bind(record.stepsBaseline, to: 6, in: statement)
        bind(record.hrv, to: 7, in: statement)
        bind(record.hrvBaseline, to: 8, in: statement)
        bind(record.rhr, to: 9, in: statement)
        bind(record.rhrBaseline, to: 10, in: statement)
        bind(record.respiratoryRate, to: 11, in: statement)
        bind(record.respiratoryRateBaseline, to: 12, in: statement)
        bind(record.sleepPerformance, to: 13, in: statement)
        bind(record.sleepPerformanceBaseline, to: 14, in: statement)
        bind(record.sourceRecoverySHA256, to: 15, in: statement)
        bind(record.sourceStrainSHA256, to: 16, in: statement)
        bind(sourceArchive, to: 17, in: statement)
        bind(sourceManifestSHA256, to: 18, in: statement)
        sqlite3_bind_double(statement, 19, Date().timeIntervalSince1970)
        return sqlite3_step(statement) == SQLITE_DONE
    }

    func upsertDailyHealthRecord(_ record: DailyHealthRecord, database: OpaquePointer) -> Bool {
        guard DayKey(rawValue: record.dateKey) != nil else { return false }
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
            WHERE daily_health_metric.source = 'whoop_api'
              AND excluded.source_updated_at >= daily_health_metric.source_updated_at
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
        if record.source == "whoop_api", let sleepJSON = record.sourceSleepPayloadJSON {
            return upsertWhoopAPISource(
                dateKey: record.dateKey,
                sleepJSON: sleepJSON,
                recoveryJSON: record.sourceRecoveryPayloadJSON,
                sourceArchive: record.sourceArchive,
                database: database
            )
        }
        return true
    }

    func upsertWhoopAPISource(
        dateKey: String,
        sleepJSON: String,
        recoveryJSON: String?,
        sourceArchive: String?,
        database: OpaquePointer
    ) -> Bool {
        let sourceSQL = """
            INSERT INTO whoop_api_source_record
            (date_key, sleep_payload_json, recovery_payload_json, source_archive, imported_at)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(date_key) DO UPDATE SET
                sleep_payload_json = excluded.sleep_payload_json,
                recovery_payload_json = excluded.recovery_payload_json,
                source_archive = excluded.source_archive,
                imported_at = excluded.imported_at
            """
        var sourceStatement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sourceSQL, -1, &sourceStatement, nil) == SQLITE_OK,
            let sourceStatement
        else { return false }
        bind(dateKey, to: 1, in: sourceStatement)
        bind(sleepJSON, to: 2, in: sourceStatement)
        bind(recoveryJSON, to: 3, in: sourceStatement)
        bind(sourceArchive, to: 4, in: sourceStatement)
        sqlite3_bind_double(sourceStatement, 5, Date().timeIntervalSince1970)
        let sourceSucceeded = sqlite3_step(sourceStatement) == SQLITE_DONE
        sqlite3_finalize(sourceStatement)
        guard sourceSucceeded else { return false }

        var deleteStatement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database,
                "DELETE FROM whoop_api_numeric_metric WHERE date_key = ?",
                -1,
                &deleteStatement,
                nil
            ) == SQLITE_OK, let deleteStatement
        else { return false }
        bind(dateKey, to: 1, in: deleteStatement)
        let deleteSucceeded = sqlite3_step(deleteStatement) == SQLITE_DONE
        sqlite3_finalize(deleteStatement)
        guard deleteSucceeded else { return false }

        let metricSQL = """
            INSERT INTO whoop_api_numeric_metric
            (date_key, source_kind, field_path, value) VALUES (?, ?, ?, ?)
            """
        var metricStatement: OpaquePointer?
        guard
            sqlite3_prepare_v2(
                database, metricSQL, -1, &metricStatement, nil
            ) == SQLITE_OK, let metricStatement
        else { return false }
        defer { sqlite3_finalize(metricStatement) }

        for (kind, payload) in [("sleep", sleepJSON), ("recovery", recoveryJSON)] {
            guard let payload,
                let data = payload.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            var metrics: [(String, Double)] = []
            Self.flattenNumericJSON(object, path: "", into: &metrics)
            for (path, value) in metrics where !path.isEmpty {
                bind(dateKey, to: 1, in: metricStatement)
                bind(kind, to: 2, in: metricStatement)
                bind(path, to: 3, in: metricStatement)
                sqlite3_bind_double(metricStatement, 4, value)
                let succeeded = sqlite3_step(metricStatement) == SQLITE_DONE
                guard succeeded else { return false }
                sqlite3_reset(metricStatement)
                sqlite3_clear_bindings(metricStatement)
            }
        }
        return true
    }

    static func flattenNumericJSON(
        _ value: Any,
        path: String,
        into output: inout [(String, Double)]
    ) {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                let childPath = path.isEmpty ? key : "\(path).\(key)"
                if let child = dictionary[key] {
                    flattenNumericJSON(child, path: childPath, into: &output)
                }
            }
        } else if let array = value as? [Any] {
            for (index, child) in array.enumerated() {
                flattenNumericJSON(child, path: "\(path)[\(index)]", into: &output)
            }
        } else if let number = value as? NSNumber {
            output.append((path, number.doubleValue))
        }
    }
}
