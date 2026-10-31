import Foundation
import SQLite3

/// Connection ownership stays with the caller's serial queue. A failed SELECT
/// never returns a prefix; empty, NULL and actual zero are distinct results.
enum SQLiteRead {
    enum Binding {
        case text(String)
        case real(Double)
        case integer(Int64)
        case blob(Data)
        case null
    }
    enum Scalar<Value: Equatable>: Equatable {
        case noRow
        case null
        case value(Value)
    }
    enum ReadError: LocalizedError {
        case invalidResult(String)
        var errorDescription: String? {
            switch self {
            case .invalidResult(let detail): detail
            }
        }
    }

    static func rows<Row>(
        _ database: OpaquePointer, sql: String, bindings: [Binding] = [],
        map: (OpaquePointer) throws -> Row
    ) throws -> [Row] {
        var candidate: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &candidate, nil)
        guard prepared == SQLITE_OK, let statement = candidate else {
            if let candidate { sqlite3_finalize(candidate) }
            throw WhoopStorageFailure.sqlite(operation: .read, database: database, resultCode: prepared)
        }
        defer { sqlite3_finalize(statement) }
        guard Int(sqlite3_bind_parameter_count(statement)) == bindings.count else {
            throw WhoopStorageFailure.sqlite(operation: .read, database: database, resultCode: SQLITE_RANGE)
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch binding {
            case .text(let value):
                result = value.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .real(let value): result = sqlite3_bind_double(statement, index, value)
            case .integer(let value): result = sqlite3_bind_int64(statement, index, value)
            case .blob(let value):
                result =
                    value.isEmpty
                    ? sqlite3_bind_zeroblob(statement, index, 0)
                    : value.withUnsafeBytes {
                        sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient)
                    }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw WhoopStorageFailure.sqlite(operation: .read, database: database, resultCode: result)
            }
        }
        var values: [Row] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else {
                throw WhoopStorageFailure.sqlite(operation: .read, database: database, resultCode: result)
            }
            values.append(try map(statement))
        }
    }

    static func integer(
        _ database: OpaquePointer, sql: String, bindings: [Binding] = []
    ) throws -> Scalar<Int64> {
        let values: [Int64?] = try rows(database, sql: sql, bindings: bindings) {
            if sqlite3_column_type($0, 0) == SQLITE_NULL { return nil }
            guard sqlite3_column_type($0, 0) == SQLITE_INTEGER else {
                throw ReadError.invalidResult("Integer SELECT returned a non-integer value")
            }
            return sqlite3_column_int64($0, 0)
        }
        guard values.count <= 1 else { throw ReadError.invalidResult("Scalar SELECT returned multiple rows") }
        guard let row = values.first else { return .noRow }
        guard let row else { return .null }
        return .value(row)
    }

    static func text(_ database: OpaquePointer, sql: String, bindings: [Binding] = []) throws -> Scalar<String> {
        let values: [String?] = try rows(database, sql: sql, bindings: bindings) {
            sqlite3_column_text($0, 0).map { String(cString: $0) }
        }
        guard values.count <= 1 else { throw ReadError.invalidResult("Scalar SELECT returned multiple rows") }
        guard let row = values.first else { return .noRow }
        guard let row else { return .null }
        return .value(row)
    }

    static func requiredInteger(_ database: OpaquePointer, sql: String) throws -> Int64 {
        guard case .value(let value) = try integer(database, sql: sql) else {
            throw ReadError.invalidResult("Required scalar SELECT returned no value")
        }
        return value
    }
}
