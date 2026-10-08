import Foundation
import OSLog
import SQLite3

/// Diagnostics cannot delay raw-packet commits. Coalesce duplicate requests
/// while one bounded report reads its own consistent WAL snapshot.
final class WhoopDiagnosticsReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "whoop.diagnostic-reader", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var latest: (URL, Date)?

    func write(at url: URL, now: Date) {
        lock.lock()
        latest = (url, now)
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        lock.unlock()
        queue.async { [self] in
            while let (url, now) = takeRequest() {
                do {
                    let report = try Self.read(at: url, now: now)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(report).write(
                        to: url.deletingLastPathComponent().appendingPathComponent("sleep-diagnostics.json"),
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch {
                    WhoopStore.logger.error("Diagnostic read failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func takeRequest() -> (URL, Date)? {
        lock.lock()
        defer { lock.unlock() }
        let request = latest
        latest = nil
        if request == nil { running = false }
        return request
    }

    static func read(at url: URL, now: Date) throws -> WhoopSleepDiagnostics {
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw WhoopStorageFailure.sqlite(operation: .read, database: nil, resultCode: result)
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 1000)
        guard sqlite3_exec(handle, "BEGIN DEFERRED", nil, nil, nil) == SQLITE_OK else {
            throw WhoopStorageFailure.sqlite(operation: .read, database: handle, resultCode: sqlite3_errcode(handle))
        }
        defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
        return WhoopSleepDiagnosticsBuilder(database: handle).build(now: now)
    }
}
