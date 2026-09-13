import Foundation
import SQLite3

/// Keeps dashboard reads off the ingestion writer. WAL provides a coherent
/// snapshot while raw packets continue committing on the single writer.
final class DashboardDatabaseReader: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.clintonst.sleep.whoop-dashboard-reader",
        qos: .userInitiated
    )
    private let repository = DashboardRepository()
    private var connection: OpaquePointer?
    private var openURL: URL?

    deinit {
        if let connection { sqlite3_close_v2(connection) }
    }

    func loadSnapshot(
        at url: URL,
        completion: @escaping @Sendable (Result<DashboardHistorySnapshot, Error>) -> Void
    ) {
        queue.async { [self] in
            completion(read(at: url) { try repository.loadSnapshot(database: $0) })
        }
    }

    func loadStepRecords(
        at url: URL,
        completion: @escaping @Sendable (Result<[DailyStepRecord], Error>) -> Void
    ) {
        queue.async { [self] in
            completion(read(at: url) { try repository.loadDailyStepRecords(database: $0) })
        }
    }

    func loadRecoveryRecords(
        at url: URL,
        completion: @escaping @Sendable (Result<[DailyRecoveryRecord], Error>) -> Void
    ) {
        queue.async { [self] in
            completion(read(at: url) { try repository.loadDailyRecoveryRecords(database: $0) })
        }
    }

    private func read<Value>(
        at url: URL,
        operation: (OpaquePointer) throws -> Value
    ) -> Result<Value, Error> {
        let signpost = WhoopRuntimeDiagnostics.signposter.beginInterval("DashboardRead")
        defer {
            WhoopRuntimeDiagnostics.signposter.endInterval("DashboardRead", signpost)
        }
        do {
            let database = try openIfNeeded(at: url)
            let begin = sqlite3_exec(database, "BEGIN DEFERRED", nil, nil, nil)
            guard begin == SQLITE_OK else {
                throw WhoopStorageFailure.sqlite(
                    operation: .read,
                    database: database,
                    resultCode: begin
                )
            }
            do {
                let value = try operation(database)
                let commit = sqlite3_exec(database, "COMMIT", nil, nil, nil)
                guard commit == SQLITE_OK else {
                    throw WhoopStorageFailure.sqlite(
                        operation: .read,
                        database: database,
                        resultCode: commit
                    )
                }
                return .success(value)
            } catch {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                throw error
            }
        } catch {
            return .failure(error)
        }
    }

    private func openIfNeeded(at url: URL) throws -> OpaquePointer {
        if let connection, openURL == url { return connection }
        if let connection { sqlite3_close_v2(connection) }
        connection = nil
        openURL = nil

        var candidate: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &candidate,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let candidate else {
            let failure = WhoopStorageFailure.sqlite(
                operation: .read,
                database: candidate,
                resultCode: result
            )
            if let candidate { sqlite3_close_v2(candidate) }
            throw failure
        }
        sqlite3_extended_result_codes(candidate, 1)
        guard sqlite3_busy_timeout(candidate, 5_000) == SQLITE_OK,
            sqlite3_exec(candidate, "PRAGMA query_only=ON", nil, nil, nil) == SQLITE_OK,
            sqlite3_exec(candidate, "PRAGMA foreign_keys=ON", nil, nil, nil) == SQLITE_OK
        else {
            let failure = WhoopStorageFailure.sqlite(
                operation: .read,
                database: candidate,
                resultCode: sqlite3_errcode(candidate)
            )
            sqlite3_close_v2(candidate)
            throw failure
        }
        connection = candidate
        openURL = url
        return candidate
    }
}
