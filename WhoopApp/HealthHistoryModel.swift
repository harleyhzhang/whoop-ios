import Foundation
import Observation

@Observable
@MainActor
final class HealthHistoryModel {
    private(set) var snapshot = DashboardHistorySnapshot.empty
    private(set) var errorMessage: String?

    @ObservationIgnored
    private let load: (@escaping @Sendable (Result<DashboardHistorySnapshot, Error>) -> Void) -> Void
    @ObservationIgnored
    private var reloadGeneration = 0
    @ObservationIgnored
    private var reloadInFlight = false

    init(
        load: @escaping (@escaping @Sendable (Result<DashboardHistorySnapshot, Error>) -> Void) -> Void = {
            WhoopStore.shared.loadDashboardHistory(completion: $0)
        }
    ) {
        self.load = load
    }

    /// Applies one freshly derived night without waiting for the full reload, so
    /// the dashboard can update immediately after automatic publication.
    func merge(_ record: DailyHealthRecord) {
        var healthRecords = snapshot.healthRecords
        if let index = healthRecords.firstIndex(where: { $0.dateKey == record.dateKey }) {
            healthRecords[index] = record
        } else {
            healthRecords.append(record)
            healthRecords.sort { lhs, rhs in
                guard let lhsKey = DayKey(rawValue: lhs.dateKey) else { return false }
                guard let rhsKey = DayKey(rawValue: rhs.dateKey) else { return true }
                return lhsKey < rhsKey
            }
        }
        snapshot = DashboardHistorySnapshot(
            healthRecords: healthRecords,
            stepRecords: snapshot.stepRecords,
            recoveryRecords: snapshot.recoveryRecords,
            strainRecords: snapshot.strainRecords,
            strainDerivations: snapshot.strainDerivations
        )
    }

    func reload() {
        if DemoHistory.isEnabled {
            snapshot = DemoHistory.snapshot()
            return
        }
        reloadGeneration += 1
        guard !reloadInFlight else { return }
        startReload()
    }

    private func startReload() {
        reloadInFlight = true
        let generation = reloadGeneration
        load { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.reloadInFlight = false
                guard generation == self.reloadGeneration else {
                    self.startReload()
                    return
                }
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.errorMessage = nil
                case .failure(let error):
                    // Preserve every last known-good dataset through a
                    // transient read failure instead of blanking its charts.
                    self.errorMessage = error.localizedDescription
                }
            }
        }
    }
}
