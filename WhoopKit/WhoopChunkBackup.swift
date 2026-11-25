import Foundation
import OSLog
import SQLite3

/// Progressive, chunked backup of every rowid table.
///
/// Rows live in fixed rowid ranges (`chunkShift` bits, 65,536 rows). Triggers
/// bump a per-chunk version on every insert, update and delete, so a pass only
/// re-reads chunks that actually changed; it never scans or hashes the growing
/// history. Each changed chunk becomes `backup/<table>/<chunk>.sqlite3`, and a
/// small manifest lists versions so a Mac pull copies only changed chunk files.
enum WhoopChunkBackup {
    static let directoryName = "backup"
    static let trackingTable = "whoop_backup_chunk"
    static let chunkShift = 16
    static let manifestVersion = 1
    private static let logger = Logger(subsystem: "whoop", category: "ChunkBackup")

    // MARK: Tracking (runs on the writer connection after migrations)

    /// Creates the version table and per-table triggers. A table that gains its
    /// triggers here (new install, new or rebuilt table) has every existing
    /// chunk marked changed from its maximum rowid, without scanning rows.
    static func ensureTracking(database: OpaquePointer) -> Bool {
        guard
            exec(
                database,
                """
                CREATE TABLE IF NOT EXISTS \(trackingTable) (
                    tbl TEXT NOT NULL, chunk INTEGER NOT NULL, version INTEGER NOT NULL,
                    PRIMARY KEY (tbl, chunk)
                ) WITHOUT ROWID
                """)
        else { return false }
        let tables: [String]
        let triggers: Set<String>
        do {
            tables = try trackedTables(database: database)
            triggers = Set(try strings(database, "SELECT name FROM sqlite_master WHERE type = 'trigger'"))
        } catch {
            return false
        }
        for table in tables where !triggers.contains(triggerName(table, "ins")) {
            let quoted = quote(table)
            let literal = table.replacingOccurrences(of: "'", with: "''")
            func mark(_ row: String) -> String {
                """
                INSERT INTO \(trackingTable)(tbl, chunk, version) VALUES ('\(literal)', \(row).rowid >> \(chunkShift), 1)
                    ON CONFLICT(tbl, chunk) DO UPDATE SET version = version + 1;
                """
            }
            let statements = [
                "BEGIN IMMEDIATE",
                """
                CREATE TRIGGER IF NOT EXISTS \(quote(triggerName(table, "ins"))) AFTER INSERT ON \(quoted)
                BEGIN \(mark("NEW")) END
                """,
                """
                CREATE TRIGGER IF NOT EXISTS \(quote(triggerName(table, "upd"))) AFTER UPDATE ON \(quoted)
                BEGIN \(mark("OLD")) \(mark("NEW")) END
                """,
                """
                CREATE TRIGGER IF NOT EXISTS \(quote(triggerName(table, "del"))) AFTER DELETE ON \(quoted)
                BEGIN \(mark("OLD")) END
                """,
                """
                WITH RECURSIVE c(n) AS (
                    SELECT 0 WHERE (SELECT MAX(rowid) FROM \(quoted)) IS NOT NULL
                    UNION ALL
                    SELECT n + 1 FROM c WHERE n < (SELECT MAX(rowid) FROM \(quoted)) >> \(chunkShift)
                )
                INSERT INTO \(trackingTable)(tbl, chunk, version) SELECT '\(literal)', n, 1 FROM c WHERE true
                    ON CONFLICT(tbl, chunk) DO UPDATE SET version = version + 1
                """,
                "COMMIT",
            ]
            for statement in statements where !exec(database, statement) {
                _ = exec(database, "ROLLBACK")
                return false
            }
        }
        return true
    }

    static func triggerName(_ table: String, _ kind: String) -> String { "whoop_backup_\(table)_\(kind)" }

    // MARK: Manifest

    struct ChunkEntry: Codable, Equatable {
        var version: Int64
        var rows: Int64
        var bytes: Int64
    }

    struct Manifest: Codable, Equatable {
        var manifestVersion: Int
        var schemaVersion: Int64
        var chunkShift: Int
        var updatedAt: String
        /// CREATE TABLE statements, so a restore rebuilds the same schema.
        var tables: [String: String]
        /// Keyed `<table>/<chunk>`.
        var chunks: [String: ChunkEntry]
        /// Chunks still waiting after the last bounded pass.
        var pending: Int
    }

    static func manifestURL(directory: URL) -> URL { directory.appendingPathComponent("manifest.json") }

    static func loadManifest(directory: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL(directory: directory)) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Manifest.self, from: data)
    }

    // MARK: Pass (read-only on the live database)

    struct PassResult: Equatable {
        let written: [String]
        let pending: Int
    }

    /// Writes changed chunks, newest first, until `budget` seconds elapse.
    @discardableResult
    static func runPass(databaseURL: URL, now: Date, budget: TimeInterval = 15) throws -> PassResult {
        let started = Date()
        let directory = databaseURL.deletingLastPathComponent().appendingPathComponent(directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest =
            loadManifest(directory: directory)
            ?? Manifest(
                manifestVersion: manifestVersion, schemaVersion: 0, chunkShift: chunkShift, updatedAt: "",
                tables: [:], chunks: [:], pending: 0)

        let (schemaVersion, tables, versions) = try readState(databaseURL: databaseURL)
        guard !versions.isEmpty || !tables.isEmpty else { return PassResult(written: [], pending: 0) }
        manifest.schemaVersion = schemaVersion
        manifest.tables = tables
        let fileManager = FileManager.default
        var dirty = versions.filter { key, version in
            manifest.chunks[key]?.version != version
                || !fileManager.fileExists(atPath: directory.appendingPathComponent(key + ".sqlite3").path)
        }.map(\.key)
        // Newest data first: a long first backfill never delays today's rows.
        dirty.sort { chunkNumber($0) > chunkNumber($1) || (chunkNumber($0) == chunkNumber($1) && $0 < $1) }

        var written: [String] = []
        for key in dirty {
            if !written.isEmpty, Date().timeIntervalSince(started) > budget { break }
            let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2, let chunk = Int64(parts[1]), tables[parts[0]] != nil else { continue }
            let entry = try writeChunk(
                databaseURL: databaseURL, directory: directory, table: parts[0], chunk: chunk)
            manifest.chunks[key] = entry
            written.append(key)
        }
        manifest.pending = dirty.count - written.count
        manifest.updatedAt = ISO8601DateFormatter().string(from: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(manifest).write(
            to: manifestURL(directory: directory),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        if !written.isEmpty {
            logger.info("Backed up \(written.count) chunks; \(manifest.pending) pending")
        }
        return PassResult(written: written, pending: manifest.pending)
    }

    private static func chunkNumber(_ key: String) -> Int64 {
        Int64(key.split(separator: "/").last ?? "") ?? 0
    }

    private static func readState(databaseURL: URL) throws -> (Int64, [String: String], [String: Int64]) {
        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
            let database = handle
        else {
            if let handle { sqlite3_close(handle) }
            throw WhoopDailyExport.Failure.sqlite("open")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        guard exec(database, "BEGIN DEFERRED") else { throw WhoopDailyExport.Failure.sqlite("begin") }
        defer { _ = exec(database, "ROLLBACK") }
        let hasTracking = try !strings(
            database, "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '\(trackingTable)'"
        ).isEmpty
        guard hasTracking else { return (0, [:], [:]) }
        let schemaVersion = Int64(try strings(database, "PRAGMA user_version").first ?? "0") ?? 0
        var tables: [String: String] = [:]
        for name in try trackedTables(database: database) {
            let escaped = name.replacingOccurrences(of: "'", with: "''")
            tables[name] = try strings(database, "SELECT sql FROM sqlite_master WHERE name = '\(escaped)'").first
        }
        var versions: [String: Int64] = [:]
        try query(database, "SELECT tbl, chunk, version FROM \(trackingTable)") { statement in
            guard let table = text(statement, 0) else { return }
            versions["\(table)/\(sqlite3_column_int64(statement, 1))"] = sqlite3_column_int64(statement, 2)
        }
        return (schemaVersion, tables, versions)
    }

    /// One consistent snapshot: the chunk's version and rows are read in the
    /// same transaction, so a concurrent write leaves a newer version behind.
    private static func writeChunk(databaseURL: URL, directory: URL, table: String, chunk: Int64) throws
        -> ChunkEntry
    {
        let tableDirectory = directory.appendingPathComponent(table, isDirectory: true)
        try FileManager.default.createDirectory(at: tableDirectory, withIntermediateDirectories: true)
        let finalURL = tableDirectory.appendingPathComponent("\(chunk).sqlite3")
        let temporaryURL = tableDirectory.appendingPathComponent(".\(chunk).partial.sqlite3")
        try? FileManager.default.removeItem(at: temporaryURL)
        var handle: OpaquePointer?
        guard
            sqlite3_open_v2(
                temporaryURL.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_URI, nil)
                == SQLITE_OK, let database = handle
        else {
            if let handle { sqlite3_close(handle) }
            throw WhoopDailyExport.Failure.sqlite("open chunk")
        }
        var closed = false
        defer { if !closed { sqlite3_close(database) } }
        sqlite3_busy_timeout(database, 2_000)
        let source =
            "file:\(databaseURL.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? databaseURL.path)?mode=ro"
        let lower = chunk << Int64(chunkShift)
        let upper = (chunk + 1) << Int64(chunkShift)
        let escaped = table.replacingOccurrences(of: "'", with: "''")
        guard exec(database, "PRAGMA journal_mode=OFF"),
            exec(database, "ATTACH DATABASE '\(source)' AS src"),
            exec(database, "BEGIN"),
            exec(
                database,
                """
                CREATE TABLE chunk_meta AS SELECT version FROM src.\(trackingTable)
                WHERE tbl = '\(escaped)' AND chunk = \(chunk)
                """),
            exec(
                database,
                """
                CREATE TABLE rows AS SELECT rowid AS _rowid, * FROM src.\(quote(table))
                WHERE rowid >= \(lower) AND rowid < \(upper)
                """),
            exec(database, "COMMIT"),
            exec(database, "DETACH DATABASE src")
        else {
            throw WhoopDailyExport.Failure.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        let version = Int64(try strings(database, "SELECT version FROM chunk_meta").first ?? "0") ?? 0
        let rows = Int64(try strings(database, "SELECT COUNT(*) FROM rows").first ?? "0") ?? 0
        sqlite3_close(database)
        closed = true
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporaryURL.path)
        if FileManager.default.fileExists(atPath: finalURL.path) {
            _ = try FileManager.default.replaceItemAt(finalURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
        return ChunkEntry(version: version, rows: rows, bytes: bytes)
    }

    // MARK: SQLite helpers

    static func trackedTables(database: OpaquePointer) throws -> [String] {
        try strings(
            database,
            """
            SELECT name FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != '\(trackingTable)'
              AND sql NOT LIKE '%WITHOUT ROWID%'
            ORDER BY name
            """)
    }

    private static func quote(_ identifier: String) -> String {
        "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    @discardableResult
    private static func exec(_ database: OpaquePointer, _ sql: String) -> Bool {
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        if result != SQLITE_OK {
            logger.error(
                "Chunk backup SQL failed (\(result)): \(String(cString: sqlite3_errmsg(database)), privacy: .public)")
        }
        return result == SQLITE_OK
    }

    private static func strings(_ database: OpaquePointer, _ sql: String) throws -> [String] {
        var values: [String] = []
        try query(database, sql) { statement in
            if let value = text(statement, 0) { values.append(value) }
        }
        return values
    }

    private static func query(_ database: OpaquePointer, _ sql: String, row: (OpaquePointer) -> Void) throws {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw WhoopDailyExport.Failure.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            row(statement)
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else {
            throw WhoopDailyExport.Failure.sqlite(String(cString: sqlite3_errmsg(database)))
        }
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL, let pointer = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: pointer)
    }
}
