import Foundation
import SQLite3

enum WhoopSQLiteOperation: String, Sendable {
    case open
    case configure
    case migrate
    case integrityCheck
    case beginTransaction
    case insert
    case commit
    case read
    case historicalOffload
}

struct WhoopStorageFailure: LocalizedError, Equatable, Sendable {
    enum Kind: String, Sendable {
        case busy
        case full
        case inputOutput
        case corrupt
        case cannotOpen
        case constraint
        case unavailable
        case unknown
    }

    let operation: WhoopSQLiteOperation
    let kind: Kind
    let primaryCode: Int32
    let extendedCode: Int32
    let detail: String

    var isTransient: Bool {
        kind == .busy || kind == .inputOutput || kind == .cannotOpen
    }

    var errorDescription: String? {
        "WHOOP storage \(operation.rawValue) failed (\(kind.rawValue), "
            + "SQLite \(primaryCode)/\(extendedCode)): \(detail)"
    }

    static func sqlite(
        operation: WhoopSQLiteOperation,
        database: OpaquePointer?,
        resultCode: Int32
    ) -> Self {
        let extendedCode = database.map(sqlite3_extended_errcode) ?? resultCode
        let message: String
        if let database {
            message = String(cString: sqlite3_errmsg(database))
        } else if let raw = sqlite3_errstr(resultCode) {
            message = String(cString: raw)
        } else {
            message = "unknown SQLite error"
        }
        return Self(
            operation: operation,
            kind: kind(for: resultCode),
            primaryCode: resultCode & 0xFF,
            extendedCode: extendedCode,
            detail: message
        )
    }

    static func unavailable(operation: WhoopSQLiteOperation, detail: String) -> Self {
        Self(
            operation: operation,
            kind: .unavailable,
            primaryCode: SQLITE_MISUSE,
            extendedCode: SQLITE_MISUSE,
            detail: detail
        )
    }

    private static func kind(for resultCode: Int32) -> Kind {
        switch resultCode & 0xFF {
        case SQLITE_BUSY, SQLITE_LOCKED: .busy
        case SQLITE_FULL: .full
        case SQLITE_IOERR: .inputOutput
        case SQLITE_CORRUPT, SQLITE_NOTADB: .corrupt
        case SQLITE_CANTOPEN: .cannotOpen
        case SQLITE_CONSTRAINT: .constraint
        default: .unknown
        }
    }
}

enum WhoopStorageState: Equatable, Sendable {
    case opening
    case retrying(attempt: Int, failure: WhoopStorageFailure)
    case ready
    case failed(WhoopStorageFailure)
}

struct WhoopStorageFaultInjector: Sendable {
    private let injectedFailure: @Sendable (WhoopSQLiteOperation) -> WhoopStorageFailure?

    init(_ injectedFailure: @escaping @Sendable (WhoopSQLiteOperation) -> WhoopStorageFailure?) {
        self.injectedFailure = injectedFailure
    }

    func failure(for operation: WhoopSQLiteOperation) -> WhoopStorageFailure? {
        injectedFailure(operation)
    }

    static let none = Self { _ in nil }
}

protocol WhoopPacketPersisting: Sendable {
    func appendBatch(
        _ envelopes: [WhoopPacketEnvelope],
        completion: @escaping @Sendable (WhoopPacketBatchPersistenceResult) -> Void
    )
}

final class WhoopStorageReadiness: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<URL, WhoopStorageFailure>?
    private var waiters: [@Sendable (Result<URL, WhoopStorageFailure>) -> Void] = []

    func resolve(_ result: Result<URL, WhoopStorageFailure>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let waiters = waiters
        self.waiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter(result) }
    }

    func whenResolved(
        _ completion: @escaping @Sendable (Result<URL, WhoopStorageFailure>) -> Void
    ) {
        lock.lock()
        if let result {
            lock.unlock()
            completion(result)
        } else {
            waiters.append(completion)
            lock.unlock()
        }
    }
}

enum WhoopStorageRetryPolicy {
    static let maximumAttempts = 4

    static func delaySeconds(forAttempt attempt: Int) -> Double {
        min(8, pow(2, Double(max(0, attempt))))
    }
}
