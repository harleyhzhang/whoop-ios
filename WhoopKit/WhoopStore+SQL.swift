import CryptoKit
import Foundation
import OSLog
import SQLite3

/// Low-level SQLite statement, transaction, and binding helpers.
extension WhoopStore {
    @discardableResult
    func execute(_ sql: String) -> Bool {
        guard let database else { return false }
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        if result != SQLITE_OK {
            Self.logger.error("SQLite operation failed (\(result)): \(self.errorMessage(database), privacy: .public)")
        }
        return result == SQLITE_OK
    }

    enum TransactionMode {
        case deferred
        case immediate

        var beginSQL: String {
            switch self {
            case .deferred: "BEGIN DEFERRED"
            case .immediate: "BEGIN IMMEDIATE"
            }
        }
    }

    func withTransaction<Value>(
        _ mode: TransactionMode,
        _ operation: (OpaquePointer) throws -> Value
    ) throws -> Value {
        guard let database else { throw StoreError.databaseUnavailable }
        guard execute(mode.beginSQL) else {
            throw StoreError.queryFailed(errorMessage(database))
        }
        do {
            let value = try operation(database)
            guard execute("COMMIT") else {
                throw StoreError.queryFailed(errorMessage(database))
            }
            return value
        } catch {
            _ = execute("ROLLBACK")
            throw error
        }
    }

    /// Cached statements are always returned to a reset, binding-free state,
    /// including when a caller exits while a SELECT is positioned on a row.
    func withCachedStatement<Value>(
        database: OpaquePointer,
        sql: String,
        _ operation: (OpaquePointer) -> Value
    ) -> Value? {
        guard let statement = cachedStatement(database: database, sql: sql) else { return nil }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        return operation(statement)
    }

    /// Returns a reset, binding-free prepared statement owned by the store.
    /// Only use this for hot paths that cannot be re-entered before the caller
    /// steps the statement; the serial store queue enforces that invariant.
    func cachedStatement(database: OpaquePointer, sql: String) -> OpaquePointer? {
        if let statement = cachedStatements[sql] {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            return statement
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            Self.logger.error("SQLite prepare failed: \(self.errorMessage(database), privacy: .public)")
            return nil
        }
        cachedStatements[sql] = statement
        return statement
    }

    func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    func bind(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            bind(value, to: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) {
        _ = value.withUnsafeBytes {
            sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient)
        }
    }

    func bind(_ value: Double?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func bind(_ value: Int64?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            sqlite3_bind_int64(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    func textColumn(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
            let bytes = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: bytes)
    }

    func doubleColumn(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    func int64Column(_ statement: OpaquePointer, _ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    func dataColumn(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
            let bytes = sqlite3_column_blob(statement, index)
        else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    func scalarInt(_ database: OpaquePointer, sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else { throw StoreError.queryFailed(errorMessage(database)) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    func errorMessage(_ database: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(database))
    }

    enum StoreError: LocalizedError {
        case databaseUnavailable
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseUnavailable: "The local WHOOP database is unavailable."
            case .queryFailed(let detail): "The WHOOP history query failed: \(detail)"
            }
        }
    }
}
