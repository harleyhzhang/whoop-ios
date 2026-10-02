import Foundation

enum WhoopReplicaClientError: Error {
    case invalidResponse
    case server(Int, String)
}

actor WhoopReplicaClient {
    private let siteURL: URL
    private let uploadToken: String
    private let session: URLSession
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(siteURL: URL, uploadToken: String, session: URLSession = .shared) {
        self.siteURL = siteURL
        self.uploadToken = uploadToken
        self.session = session
    }

    func missing(chunkIds: [String]) async throws -> Set<String> {
        struct Body: Encodable { let chunkIds: [String] }
        struct Response: Decodable { let missing: [String] }
        let response: Response = try await request(
            path: "/v1/phone/missing",
            method: "POST",
            body: Body(chunkIds: chunkIds)
        )
        return Set(response.missing)
    }

    func upload(identifier: String, encrypted: Data, createdAt: Date) async throws {
        struct Empty: Encodable {}
        struct UploadURLResponse: Decodable { let uploadUrl: URL }
        struct StorageResponse: Decodable { let storageId: String }
        struct CommitBody: Encodable {
            let chunkId: String
            let createdAt: Int64
            let encryptedBytes: Int
            let storageId: String
        }
        struct CommitResponse: Decodable { let reused: Bool }
        let target: UploadURLResponse = try await request(
            path: "/v1/phone/upload-url",
            method: "POST",
            body: Empty()
        )
        var uploadRequest = URLRequest(url: target.uploadUrl)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "content-type")
        let (responseData, response) = try await session.upload(for: uploadRequest, from: encrypted)
        try validate(response: response, data: responseData)
        let storage = try decoder.decode(StorageResponse.self, from: responseData)
        let _: CommitResponse = try await request(
            path: "/v1/phone/commit-chunk",
            method: "POST",
            body: CommitBody(
                chunkId: identifier,
                createdAt: Int64(createdAt.timeIntervalSince1970 * 1_000),
                encryptedBytes: encrypted.count,
                storageId: storage.storageId
            )
        )
    }

    func commit(manifest: WhoopReplicaSnapshotManifest) async throws {
        struct Response: Decodable { let reused: Bool }
        let _: Response = try await request(
            path: "/v1/phone/commit-snapshot",
            method: "POST",
            body: manifest
        )
    }

    private func request<Body: Encodable, Response: Decodable>(
        path: String,
        method: String,
        body: Body
    ) async throws -> Response {
        var request = URLRequest(url: siteURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = try encoder.encode(body)
        request.setValue("Bearer \(uploadToken)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)
        return try decoder.decode(Response.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw WhoopReplicaClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw WhoopReplicaClientError.server(
                http.statusCode,
                String(data: data.prefix(512), encoding: .utf8) ?? ""
            )
        }
    }
}
