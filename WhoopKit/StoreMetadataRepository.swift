import SQLite3

/// Existing metadata writes remain confined to the single SQLite writer queue.
struct StoreMetadataRepository {
    func set(
        database: OpaquePointer,
        key: String,
        value: String
    ) -> Bool {
        let sql = """
            INSERT INTO whoop_store_metadata(key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard key.withCString({ sqlite3_bind_text(statement, 1, $0, -1, transient) }) == SQLITE_OK,
            value.withCString({ sqlite3_bind_text(statement, 2, $0, -1, transient) }) == SQLITE_OK
        else { return false }
        return sqlite3_step(statement) == SQLITE_DONE
    }

}
