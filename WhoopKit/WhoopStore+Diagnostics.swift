import Foundation

extension WhoopStore {
    func writeSleepDiagnostics(now: Date = .now) {
        // Preserve ordering with requested analysis, then release the writer.
        queue.async { [self] in
            guard let databaseURL, database != nil else { return }
            diagnosticsReader.write(at: databaseURL, now: now)
        }
    }
}
