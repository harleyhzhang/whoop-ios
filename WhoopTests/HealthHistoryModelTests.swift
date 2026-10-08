import XCTest

@testable import Whoop

final class HealthHistoryModelTests: XCTestCase {
    @MainActor
    func testConcurrentRefreshesCoalesceAndObsoleteResultsCannotBlankHistory() async {
        var completions: [@Sendable (Result<DashboardHistorySnapshot, Error>) -> Void] = []
        let third = expectation(description: "next requested reload")
        let restarted = expectation(description: "one coalesced reload")
        let model = HealthHistoryModel { completion in
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
}
