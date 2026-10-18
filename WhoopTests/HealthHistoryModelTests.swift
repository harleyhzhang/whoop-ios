import XCTest

@testable import Whoop

final class HealthHistoryModelTests: XCTestCase {
    @MainActor
    func testConcurrentRefreshesCoalesceAndObsoleteResultsCannotBlankHistory() async {
        var completions: [@Sendable (Result<DashboardHistorySnapshot, Error>) -> Void] = []
        let third = expectation(description: "next requested reload")
        let restarted = expectation(description: "one coalesced reload")
        let model = HealthHistoryModel(cache: nil) { completion in
            completions.append(completion)
            if completions.count == 2 { restarted.fulfill() }
            if completions.count == 3 { third.fulfill() }
        }
        XCTAssertEqual(completions.count, 0, "Construction during background restoration must not read the dashboard")
        for _ in 0..<20 { model.reload() }
        XCTAssertEqual(completions.count, 1)
        completions[0](.failure(NSError(domain: "obsolete", code: 1)))
        await fulfillment(of: [restarted], timeout: 2)
        XCTAssertEqual(completions.count, 2)
        XCTAssertNil(model.errorMessage)
        completions[1](.success(.empty))
        model.reload()
        await fulfillment(of: [third], timeout: 2)
        XCTAssertEqual(completions.count, 3)
    }

    @MainActor
    func testColdStartShowsCachedDashboardBeforeTheFirstStoreRead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dashboard-snapshot-v1.json")
        let writer = DashboardSnapshotCache(url: url)
        let written = expectation(description: "cache written")
        writer.save(Self.snapshot(sleepScore: 88)) { written.fulfill() }
        await fulfillment(of: [written], timeout: 2)

        var reads = 0
        let model = HealthHistoryModel(cache: DashboardSnapshotCache(url: url)) { _ in reads += 1 }

        XCTAssertEqual(reads, 0, "Cached values must not wait for the store")
        XCTAssertEqual(model.snapshot.healthRecords.map(\.sleepScore), [88])
        XCTAssertEqual(model.snapshot.stepRecords.map(\.stepCount), [5_432])
        XCTAssertEqual(model.snapshot.recoveryRecords.map(\.score), [81])
        XCTAssertEqual(model.snapshot.strainRecords.map(\.score), [12.5])
        XCTAssertTrue(model.snapshot.strainDerivations.isEmpty, "Pending store writes are never cached")
    }

    @MainActor
    func testSuccessfulReadReplacesAndPersistsCachedDashboard() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("dashboard-snapshot-v1.json")
        let cache = DashboardSnapshotCache(url: url)
        let seeded = expectation(description: "cache seeded")
        cache.save(Self.snapshot(sleepScore: 70)) { seeded.fulfill() }
        await fulfillment(of: [seeded], timeout: 2)
        let fresh = Self.snapshot(sleepScore: 91)
        let loaded = expectation(description: "store read delivered")
        let model = HealthHistoryModel(cache: cache) { completion in
            completion(.success(fresh))
            loaded.fulfill()
        }
        XCTAssertEqual(model.snapshot.healthRecords.map(\.sleepScore), [70])

        model.reload()
        await fulfillment(of: [loaded], timeout: 2)
        for _ in 0..<1_000 where model.snapshot.healthRecords.first?.sleepScore != 91 {
            await Task.yield()
        }
        XCTAssertEqual(model.snapshot.healthRecords.map(\.sleepScore), [91])
        // Poll a fresh reader so only the model's own save can satisfy this.
        var relaunched: DashboardHistorySnapshot?
        for _ in 0..<200 where relaunched?.healthRecords.first?.sleepScore != 91 {
            try await Task.sleep(for: .milliseconds(10))
            relaunched = DashboardSnapshotCache(url: url).cachedSnapshot()
        }
        XCTAssertEqual(relaunched?.healthRecords.map(\.sleepScore), [91])
    }

    private static func snapshot(sleepScore: Double) -> DashboardHistorySnapshot {
        DashboardHistorySnapshot(
            healthRecords: [
                DailyHealthRecord(
                    dateKey: "2026-09-09", sleepScore: sleepScore, sleepDurationMinutes: 480,
                    hrvRMSSDMilliseconds: 64, restingHeartRateBPM: 52, sleepID: "synthetic", cycleID: nil,
                    source: "synthetic", sourceArchive: nil, sourceUpdatedAt: "2026-09-09T12:00:00Z")
            ],
            stepRecords: [
                DailyStepRecord(
                    dateKey: "2026-09-09", stepCount: 5_432, sampleCount: 2, spanSeconds: 2,
                    coverageFraction: 1, gapSeconds: 0, counterWrapCount: 0, rejectedDeltaCount: 0,
                    firstSampleAt: nil, lastSampleAt: nil, source: "synthetic", algorithmVersion: 1)
            ],
            recoveryRecords: [DailyRecoveryRecord(dateKey: "2026-09-09", score: 81, source: "synthetic")],
            strainRecords: [
                DailyStrainRecord(dateKey: "2026-09-09", score: 12.5, source: "synthetic", estimate: nil)
            ],
            strainDerivations: ["local-strain-input.v1.synthetic": "{}"]
        )
    }
}
