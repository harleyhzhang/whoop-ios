import Compression
import CryptoKit
import Foundation

enum WhoopReplicaReason: Sendable {
    case launch
    case foreground
    case dataChanged
    case sleepPublished

    var minimumSuccessInterval: TimeInterval {
        switch self {
        case .sleepPublished: 60 * 60
        case .launch, .foreground, .dataChanged: 6 * 60 * 60
        }
    }
}

enum WhoopReplicaSyncPolicy {
    static let retryInterval: TimeInterval = 15 * 60

    static func shouldStart(
        reason: WhoopReplicaReason,
        now: Date,
        lastSuccess: Date?,
        lastAttempt: Date?
    ) -> Bool {
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryInterval {
            return false
        }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= reason.minimumSuccessInterval
    }
}

struct WhoopReplicaConfiguration: Sendable {
    let siteURL: URL
    let uploadToken: String
    let encryptionKey: Data

    private struct Resource: Decodable {
        let siteURL: String
        let uploadToken: String
        let encryptionKeyBase64: String
    }

    static func load(bundle: Bundle = .main) -> WhoopReplicaConfiguration? {
        guard let url = bundle.url(forResource: "whoop-replica-config", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let resource = try? JSONDecoder().decode(Resource.self, from: data),
            let siteURL = URL(string: resource.siteURL),
            let key = Data(base64Encoded: resource.encryptionKeyBase64),
            key.count == 32,
            !resource.uploadToken.isEmpty
        else { return nil }
        return WhoopReplicaConfiguration(
            siteURL: siteURL,
            uploadToken: resource.uploadToken,
            encryptionKey: key
        )
    }
}

struct WhoopReplicaChunkDescriptor: Sendable {
    let index: Int
    let identifier: String
    let plainBytes: Int
}

struct WhoopReplicaSnapshotManifest: Encodable, Sendable {
    let chunkIds: [String]
    let chunkPlainBytes: [Int]
    let chunkSize: Int
    let createdAt: Int64
    let schemaVersion: Int
    let sourceBytes: Int64
    let sourceFingerprint: String
}

enum WhoopReplicaCodecError: Error {
    case compressionFailed
    case invalidKey
}

enum WhoopReplicaCodec {
    static let chunkSize = 8 * 1024 * 1024

    static func key(from data: Data) throws -> SymmetricKey {
        guard data.count == 32 else { throw WhoopReplicaCodecError.invalidKey }
        return SymmetricKey(data: data)
    }

    static func chunkIdentifier(
        key: SymmetricKey,
        index: Int,
        plaintext: Data
    ) -> String {
        var bigEndian = UInt64(index).bigEndian
        var authenticated = Data(bytes: &bigEndian, count: MemoryLayout<UInt64>.size)
        authenticated.append(plaintext)
        return Data(HMAC<SHA256>.authenticationCode(for: authenticated, using: key)).hexString
    }

    static func encrypt(
        plaintext: Data,
        identifier: String,
        key: SymmetricKey
    ) throws -> Data {
        let compressed = try compress(plaintext)
        let sealed = try AES.GCM.seal(
            compressed,
            using: key,
            authenticating: Data(identifier.utf8)
        )
        guard let combined = sealed.combined else { throw WhoopReplicaCodecError.compressionFailed }
        return combined
    }

    private static func compress(_ source: Data) throws -> Data {
        let capacity = source.count + source.count / 1_000 + 128
        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { destinationBuffer in
            source.withUnsafeBytes { sourceBuffer in
                guard
                    let destinationAddress = destinationBuffer.bindMemory(to: UInt8.self).baseAddress,
                    let sourceAddress = sourceBuffer.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                return compression_encode_buffer(
                    destinationAddress,
                    capacity,
                    sourceAddress,
                    source.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { throw WhoopReplicaCodecError.compressionFailed }
        destination.removeSubrange(written..<destination.count)
        return destination
    }

}

extension Data {
    fileprivate var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
