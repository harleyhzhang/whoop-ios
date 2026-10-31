import Foundation
import OSLog

extension WhoopStore {
    /// Runs on launch even without an active scene. Expensive replay stays on
    /// the read-only dashboard queue; only metadata returns to the writer.
    func refreshLocalStrainProjection() {
        loadDashboardHistory { result in
            if case .failure(let error) = result {
                Self.logger.error("Strain projection refresh failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Publish a complete versioned backfill atomically. Official/imported
    /// scores, old engine versions, calibration archives and raw rows stay intact.
    @discardableResult
    func persistStrainDerivations(_ derivations: [String: String]) -> Bool {
        guard !derivations.isEmpty, let database else { return false }
        let summaryKey = "local-strain-backfill." + StrainAccumulator.version
        var firstProjection = false
        if derivations[summaryKey] != nil,
            case .noRow? = try? metadataValue(database: database, key: summaryKey)
        {
            firstProjection = true
        }
        guard execute("BEGIN IMMEDIATE") else { return false }
        for key in derivations.keys.sorted() {
            guard let value = derivations[key],
                setMetadataValue(database: database, key: key, value: value)
            else {
                execute("ROLLBACK")
                return false
            }
        }
        guard execute("COMMIT") else {
            execute("ROLLBACK")
            return false
        }
        if firstProjection {
            WhoopDeploymentHealthReporter.start(force: true)
        }
        return true
    }
}
