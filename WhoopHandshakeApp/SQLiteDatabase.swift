import Foundation
import SQLite3

/// The single owner of WHOOP's mutable SQLite connection state.
///
/// SQLite exposes non-Sendable C pointers, so this narrow adapter contains the
/// store's unchecked connection boundary. Every mutable property traps unless
/// it is accessed on `queue`; higher layers are ordinary checked-Sendable values
/// and may only schedule work through that queue.
final class SQLiteDatabase: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.clintonst.sleep.whoop-store", qos: .utility)

    private let queueSpecificKey = DispatchSpecificKey<Void>()
    private var rawConnection: OpaquePointer?
    private var rawCachedStatements: [String: OpaquePointer] = [:]
    private var rawPendingStepDateKeys: Set<String> = []
    private var rawPublishedWakeBoundaries: [WhoopWakeBoundary]?
    private var rawStorageTelemetry: WhoopStorageTelemetry?
    private var rawNextDeliverySequence: Int64 = 1
    #if DEBUG
        private var rawIngestionTransactionCount = 0
    #endif

    init() {
        queue.setSpecific(key: queueSpecificKey, value: ())
    }

    var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: queueSpecificKey) != nil
    }

    var connection: OpaquePointer? {
        get {
            requireQueue()
            return rawConnection
        }
        set {
            requireQueue()
            rawConnection = newValue
        }
    }

    var cachedStatements: [String: OpaquePointer] {
        get {
            requireQueue()
            return rawCachedStatements
        }
        set {
            requireQueue()
            rawCachedStatements = newValue
        }
    }

    var pendingStepDateKeys: Set<String> {
        get {
            requireQueue()
            return rawPendingStepDateKeys
        }
        set {
            requireQueue()
            rawPendingStepDateKeys = newValue
        }
    }

    var publishedWakeBoundaries: [WhoopWakeBoundary]? {
        get {
            requireQueue()
            return rawPublishedWakeBoundaries
        }
        set {
            requireQueue()
            rawPublishedWakeBoundaries = newValue
        }
    }

    var storageTelemetry: WhoopStorageTelemetry? {
        get {
            requireQueue()
            return rawStorageTelemetry
        }
        set {
            requireQueue()
            rawStorageTelemetry = newValue
        }
    }

    var nextDeliverySequence: Int64 {
        get {
            requireQueue()
            return rawNextDeliverySequence
        }
        set {
            requireQueue()
            rawNextDeliverySequence = newValue
        }
    }

    #if DEBUG
        var ingestionTransactionCount: Int {
            get {
                requireQueue()
                return rawIngestionTransactionCount
            }
            set {
                requireQueue()
                rawIngestionTransactionCount = newValue
            }
        }
    #endif

    func close() {
        requireQueue()
        rawStorageTelemetry?.flush()
        rawStorageTelemetry = nil
        for statement in rawCachedStatements.values {
            sqlite3_finalize(statement)
        }
        rawCachedStatements.removeAll()
        if let rawConnection {
            sqlite3_close(rawConnection)
            self.rawConnection = nil
        }
    }

    private func requireQueue() {
        dispatchPrecondition(condition: .onQueue(queue))
    }
}
