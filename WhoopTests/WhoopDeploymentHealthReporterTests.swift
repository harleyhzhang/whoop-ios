import Foundation
import SQLite3
import XCTest

@testable import Whoop

final class WhoopDeploymentHealthReporterTests: XCTestCase {
    func testReportAttestsDatabaseAndArchive() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        let archiveURL = directory.appendingPathComponent("whoop-official-archive.sqlite3")
        try makeDatabase(at: databaseURL, schema: 10, rawPackets: 2)
        try makeDatabase(at: archiveURL, schema: 1, rawPackets: 0)

        let report = try WhoopDeploymentHealthReporter.makeReport(
            databaseURL: databaseURL,
            archiveURL: archiveURL,
            sourceCommit: String(repeating: "a", count: 40),
            now: Date(timeIntervalSince1970: 0)
        )
        let reportURL = directory.appendingPathComponent("report.json")
        try WhoopDeploymentHealthReporter.write(report, to: reportURL)
        let decoded = try JSONDecoder().decode(
            WhoopDeploymentHealthReport.self,
            from: Data(contentsOf: reportURL)
        )

        XCTAssertEqual(decoded, report)
        XCTAssertEqual(report.formatVersion, 1)
        XCTAssertEqual(report.schemaVersion, 10)
        XCTAssertEqual(report.quickCheck, "ok")
        XCTAssertEqual(report.foreignKeyViolations, 0)
        XCTAssertEqual(report.tableCounts["whoop_raw_packet"], 2)
        XCTAssertEqual(report.officialArchiveSHA256.count, 64)
    }

    func testReportRejectsInvalidCommitAndDatabase() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(
            try WhoopDeploymentHealthReporter.makeReport(
                databaseURL: missing,
                archiveURL: missing,
                sourceCommit: "not-a-commit"
            )
        ) { error in
            XCTAssertEqual(
                error as? WhoopDeploymentHealthReporter.ReporterError,
                .invalidCommit
            )
        }
        XCTAssertThrowsError(
            try WhoopDeploymentHealthReporter.makeReport(
                databaseURL: missing,
                archiveURL: missing,
                sourceCommit: String(repeating: "b", count: 40)
            )
        )
    }

    func testReportIncludesValidatedLocalRollbackAndCurrentStrainOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backups = directory.appendingPathComponent("migration-backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("sleep.sqlite3")
        let archive = directory.appendingPathComponent("whoop-official-archive.sqlite3")
        try makeDatabase(at: current, schema: 12, rawPackets: 3)
        try makeDatabase(at: archive, schema: 1, rawPackets: 0)
        try makeDatabase(at: backups.appendingPathComponent("sleep-v11-before-v12.sqlite3"), schema: 11, rawPackets: 2)
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(current.path, &database), SQLITE_OK)
        guard let database else { throw TestError.cannotOpenDatabase }
        defer { sqlite3_close(database) }
        let version = StrainAccumulator.version
        XCTAssertEqual(
            sqlite3_exec(database, "CREATE TABLE whoop_store_metadata(key TEXT PRIMARY KEY,value TEXT)", nil, nil, nil),
            SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "INSERT INTO whoop_store_metadata VALUES('local-strain-backfill.\(version)','summary'),('local-strain.2026-10-30.id.cal.\(version)','current'),('local-strain.2026-10-30.id.old','old')",
                nil, nil, nil), SQLITE_OK)
        let report = try WhoopDeploymentHealthReporter.makeReport(
            databaseURL: current, archiveURL: archive, sourceCommit: String(repeating: "c", count: 40))
        XCTAssertEqual(report.migrationRollbacks.count, 1)
        XCTAssertEqual(report.migrationRollbacks.first?.schemaVersion, 11)
        XCTAssertEqual(report.migrationRollbacks.first?.tableCounts["whoop_raw_packet"], 2)
        XCTAssertEqual(report.migrationRollbacks.first?.quickCheck, "ok")
        XCTAssertEqual(report.strainBackfillJSON, "summary")
        XCTAssertEqual(Array(report.strainEstimatesJSON.values), ["current"])
        XCTAssertEqual(report.tableCounts["whoop_raw_packet"], 3)
    }

    func testCorruptRollbackCannotProduceHealthyReport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let backups = directory.appendingPathComponent("migration-backups")
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("sleep.sqlite3")
        let archive = directory.appendingPathComponent("whoop-official-archive.sqlite3")
        try makeDatabase(at: current, schema: 12, rawPackets: 3)
        try makeDatabase(at: archive, schema: 1, rawPackets: 0)
        try Data("invalid".utf8).write(to: backups.appendingPathComponent("sleep-v11-before-v12.sqlite3"))
        XCTAssertThrowsError(
            try WhoopDeploymentHealthReporter.makeReport(
                databaseURL: current, archiveURL: archive, sourceCommit: String(repeating: "c", count: 40)))
    }

    private func makeDatabase(at url: URL, schema: Int, rawPackets: Int) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else { throw TestError.cannotOpenDatabase }
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version = \(schema)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                database,
                "CREATE TABLE whoop_raw_packet (id INTEGER PRIMARY KEY)",
                nil,
                nil,
                nil
            ),
            SQLITE_OK
        )
        for value in 0..<rawPackets {
            XCTAssertEqual(
                sqlite3_exec(
                    database,
                    "INSERT INTO whoop_raw_packet(id) VALUES (\(value))",
                    nil,
                    nil,
                    nil
                ),
                SQLITE_OK
            )
        }
    }

    private enum TestError: Error {
        case cannotOpenDatabase
    }
}
