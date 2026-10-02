import CryptoKit
import Foundation
import OSLog
import SQLite3

struct WhoopDeploymentHealthReport: Codable, Equatable, Sendable {
    let formatVersion: Int
    let sourceCommit: String
    let generatedAt: String
    let schemaVersion: Int
    let quickCheck: String
    let foreignKeyViolations: Int
    let tableCounts: [String: Int]
    let officialArchiveSHA256: String
}

enum WhoopDeploymentHealthReporter {
    static let fileName = "deployment-health-v1.json"
    private static let logger = Logger(
        subsystem: "whoop",
        category: "DeploymentHealth"
    )
    private static let preservedTables = [
        "whoop_raw_packet",
        "whoop_historical_sample",
        "whoop_packet_replay",
        "whoop_ppg_packet",
        "whoop_offload_session",
        "whoop_api_source_record",
        "whoop_api_numeric_metric",
        "whoop_time_zone_observation",
        "daily_health_metric",
        "whoop_official_daily_metric",
        "whoop_daily_recovery_metric",
        "whoop_daily_step_metric",
    ]

    static func start() {
        guard
            let sourceCommit = Bundle.main.object(forInfoDictionaryKey: "WHOOPSourceCommit") as? String,
            sourceCommit.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil
        else { return }
        WhoopStore.shared.publishDeploymentHealthReport(sourceCommit: sourceCommit)
    }

    static func publish(databaseURL: URL, sourceCommit: String) {
        let directory = databaseURL.deletingLastPathComponent()
        let archiveURL = directory.appendingPathComponent("whoop-official-archive.sqlite3")
        let reportURL = directory.appendingPathComponent(fileName)
        DispatchQueue.global(qos: .utility).async {
            if let current = currentReport(at: reportURL),
                current.sourceCommit == sourceCommit.lowercased(),
                current.quickCheck == "ok",
                current.foreignKeyViolations == 0
            {
                WhoopReplicaRecovery.finalizeIfHealthy(databaseURL: databaseURL)
                return
            }
            for attempt in 0..<30 {
                do {
                    let report = try makeReport(
                        databaseURL: databaseURL,
                        archiveURL: archiveURL,
                        sourceCommit: sourceCommit
                    )
                    try write(report, to: reportURL)
                    WhoopReplicaRecovery.finalizeIfHealthy(databaseURL: databaseURL)
                    return
                } catch {
                    if attempt == 29 {
                        logger.error("Deployment health report failed: \(error.localizedDescription, privacy: .public)")
                    } else {
                        Thread.sleep(forTimeInterval: 1)
                    }
                }
            }
        }
    }

    static func makeReport(
        databaseURL: URL,
        archiveURL: URL,
        sourceCommit: String,
        now: Date = .now
    ) throws -> WhoopDeploymentHealthReport {
        guard sourceCommit.range(of: "^[0-9a-fA-F]{40}$", options: .regularExpression) != nil else {
            throw ReporterError.invalidCommit
        }
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, flags, nil) == SQLITE_OK, let database
        else {
            if let database { sqlite3_close(database) }
            throw ReporterError.cannotOpenDatabase
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)

        let quickCheck = try strings(database, sql: "PRAGMA quick_check").joined(separator: ",")
        guard quickCheck == "ok" else { throw ReporterError.quickCheckFailed(quickCheck) }
        let schemaVersion = try integer(database, sql: "PRAGMA user_version")
        let foreignKeyViolations = try rowCount(database, sql: "PRAGMA foreign_key_check")
        guard foreignKeyViolations == 0 else {
            throw ReporterError.foreignKeyViolations(foreignKeyViolations)
        }
        let existingTables = Set(
            try strings(database, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
        )
        var tableCounts: [String: Int] = [:]
        for table in preservedTables where existingTables.contains(table) {
            tableCounts[table] = try integer(database, sql: "SELECT COUNT(*) FROM \"\(table)\"")
        }
        return WhoopDeploymentHealthReport(
            formatVersion: 1,
            sourceCommit: sourceCommit.lowercased(),
            generatedAt: ISO8601DateFormatter().string(from: now),
            schemaVersion: schemaVersion,
            quickCheck: quickCheck,
            foreignKeyViolations: foreignKeyViolations,
            tableCounts: tableCounts,
            officialArchiveSHA256: try sha256(archiveURL)
        )
    }

    static func write(_ report: WhoopDeploymentHealthReport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    private static func currentReport(at url: URL) -> WhoopDeploymentHealthReport? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WhoopDeploymentHealthReport.self, from: data)
    }

    private static func strings(_ database: OpaquePointer, sql: String) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw ReporterError.queryFailed(sql) }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else {
                throw ReporterError.queryFailed(sql)
            }
            values.append(String(cString: text))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ReporterError.queryFailed(sql) }
        return values
    }

    private static func integer(_ database: OpaquePointer, sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw ReporterError.queryFailed(sql) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ReporterError.queryFailed(sql) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func rowCount(_ database: OpaquePointer, sql: String) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw ReporterError.queryFailed(sql) }
        defer { sqlite3_finalize(statement) }
        var count = 0
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            count += 1
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw ReporterError.queryFailed(sql) }
        return count
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    enum ReporterError: Error, Equatable {
        case invalidCommit
        case cannotOpenDatabase
        case quickCheckFailed(String)
        case foreignKeyViolations(Int)
        case queryFailed(String)
    }
}

extension WhoopStore {
    func publishDeploymentHealthReport(sourceCommit: String) {
        readiness.whenResolved { result in
            guard case .success(let databaseURL) = result else { return }
            WhoopDeploymentHealthReporter.publish(
                databaseURL: databaseURL,
                sourceCommit: sourceCommit
            )
        }
    }
}
