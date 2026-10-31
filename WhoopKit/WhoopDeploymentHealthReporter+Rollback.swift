import Foundation
import SQLite3

struct WhoopMigrationRollbackReport: Codable, Equatable, Sendable {
    let relativePath: String
    let schemaVersion: Int
    let quickCheck: String
    let fileBytes: Int
    let modifiedAt: String
    let tableCounts: [String: Int]
}

extension WhoopDeploymentHealthReporter {
    /// Local rollback evidence is deliberately distinct from an off-phone backup.
    static func rollbackReports(databaseURL: URL, targetSchema: Int) throws -> [WhoopMigrationRollbackReport] {
        let directory = databaseURL.deletingLastPathComponent().appendingPathComponent("migration-backups")
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let suffix = "-before-v\(targetSchema).sqlite3"
        return try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("sleep-v") && $0.lastPathComponent.hasSuffix(suffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                var handle: OpaquePointer?
                guard
                    sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
                    let handle
                else {
                    if let handle { sqlite3_close(handle) }
                    throw ReporterError.cannotOpenDatabase
                }
                defer { sqlite3_close(handle) }
                guard case .value("ok") = try SQLiteRead.text(handle, sql: "PRAGMA quick_check") else {
                    throw ReporterError.quickCheckFailed("migration rollback")
                }
                let schema = Int(try SQLiteRead.requiredInteger(handle, sql: "PRAGMA user_version"))
                var tables: [String] = []
                _ = try SQLiteRead.rows(handle, sql: "SELECT name FROM sqlite_master WHERE type='table'") { row in
                    guard let value = sqlite3_column_text(row, 0) else { throw ReporterError.queryFailed("table name") }
                    tables.append(String(cString: value))
                }
                var counts: [String: Int] = [:]
                for table in preservedTables where tables.contains(table) {
                    counts[table] = Int(
                        try SQLiteRead.requiredInteger(handle, sql: "SELECT COUNT(*) FROM \"\(table)\""))
                }
                let attributes = try manager.attributesOfItem(atPath: url.path)
                guard let modified = attributes[.modificationDate] as? Date,
                    let bytes = attributes[.size] as? NSNumber
                else { throw ReporterError.cannotOpenDatabase }
                return WhoopMigrationRollbackReport(
                    relativePath: "migration-backups/" + url.lastPathComponent,
                    schemaVersion: schema, quickCheck: "ok", fileBytes: bytes.intValue,
                    modifiedAt: ISO8601DateFormatter().string(from: modified), tableCounts: counts)
            }
    }

    static func strainEvidence(database: OpaquePointer) throws -> (String?, [String: String]) {
        let exists = try SQLiteRead.requiredInteger(
            database, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='whoop_store_metadata'")
        guard exists == 1 else { return (nil, [:]) }
        var summary: String?
        var examples: [String: String] = [:]
        _ = try SQLiteRead.rows(
            database,
            sql: "SELECT key,value FROM whoop_store_metadata WHERE key=? OR (key LIKE 'local-strain.%' AND key LIKE ?)",
            bindings: [
                .text("local-strain-backfill." + StrainAccumulator.version), .text("%." + StrainAccumulator.version),
            ]
        ) { row in
            guard let rawKey = sqlite3_column_text(row, 0), let rawValue = sqlite3_column_text(row, 1) else {
                throw ReporterError.queryFailed("Strain evidence")
            }
            let key = String(cString: rawKey)
            let value = String(cString: rawValue)
            if key.hasPrefix("local-strain-backfill.") { summary = value } else { examples[key] = value }
        }
        return (summary, examples)
    }
}
