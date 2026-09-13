import SQLite3
import XCTest

@testable import Sleep

extension WhoopSleepStateTests {
    func testEmptyLegacyDatabaseMigratesIdempotentlyToCurrentSchema() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("sleep.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }
        do {
            let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let database { sqlite3_close(database) } }
        XCTAssertEqual(scalarInt(database, sql: "PRAGMA user_version"), 10)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('whoop_decode_failure','whoop_latest_heart_rate','whoop_ppg_packet','whoop_store_metadata')"
            ), 4)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='whoop_decode_result'"
            ), 0)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM pragma_table_info('whoop_ppg_packet') WHERE name='decoder_version'"
            ), 1)
        XCTAssertEqual(
            scalarInt(
                database,
                sql: "SELECT COUNT(*) FROM pragma_table_info('heart_rate_sample') WHERE name='id'"
            ), 0)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM pragma_table_info('daily_health_metric') WHERE name IN ('sleep_start_at','sleep_end_at','sleep_start_minute','sleep_end_minute','sleep_need_minutes','sleep_consistency_percentage','sleep_efficiency_percentage','sleep_sufficiency_percentage')"
            ), 8)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('whoop_api_source_record','whoop_api_numeric_metric')"
            ), 2)
        XCTAssertGreaterThanOrEqual(
            scalarInt(
                database,
                sql: "SELECT COUNT(*) FROM whoop_time_zone_observation"
            ), 1)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM pragma_table_info('whoop_historical_sample') WHERE name IN ('step_motion_counter','step_cadence_raw','motion_class_raw','step_utc_offset_seconds','step_date_key')"
            ), 5)
        XCTAssertEqual(
            scalarInt(
                database,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='whoop_daily_step_metric'"
            ), 1)
        XCTAssertEqual(
            scalarInt(
                database,
                sql:
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('whoop_official_daily_metric','whoop_daily_recovery_metric')"
            ), 2)
    }

    func testOnlineBackupIncludesCommittedWALData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceURL = directory.appendingPathComponent("source.sqlite3")
        let snapshotURL = directory.appendingPathComponent("snapshot.sqlite3")

        var source: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(
                sourceURL.path,
                &source,
                SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
                nil
            ),
            SQLITE_OK
        )
        guard let source else { return }
        defer { sqlite3_close(source) }
        XCTAssertEqual(sqlite3_exec(source, "PRAGMA journal_mode=WAL", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(source, "CREATE TABLE evidence(value TEXT NOT NULL)", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(source, "PRAGMA user_version=6", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(source, "INSERT INTO evidence VALUES ('retained')", nil, nil, nil), SQLITE_OK)

        XCTAssertTrue(WhoopStore.copySQLiteDatabase(source: source, destinationURL: snapshotURL))
        var snapshot: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(snapshotURL.path, &snapshot, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let snapshot { sqlite3_close(snapshot) } }
        XCTAssertEqual(scalarInt(snapshot, sql: "PRAGMA user_version"), 6)
        XCTAssertEqual(scalarInt(snapshot, sql: "SELECT COUNT(*) FROM evidence"), 1)
        XCTAssertEqual(scalarText(snapshot, sql: "PRAGMA quick_check"), "ok")
    }

    func testMigrationSnapshotRemovesStaleTemporarySidecars() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("sleep.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version=7", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let backupDirectory = directory.appendingPathComponent("migration-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let temporary = backupDirectory.appendingPathComponent(".migration-backup-in-progress.sqlite3")
        for path in [temporary.path, temporary.path + "-wal", temporary.path + "-shm"] {
            try Data("stale".utf8).write(to: URL(fileURLWithPath: path))
        }

        do {
            let store = WhoopStore(databaseURL: url, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path + "-shm"))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: backupDirectory.appendingPathComponent("sleep-v7-before-v10.sqlite3").path
            ))
    }

    func testSchema10MigrationCompactsRealtimeProjectionAndDecodeLedger() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let databaseURL = directory.appendingPathComponent("sleep.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        guard let database else {
            XCTFail("Could not open schema fixture")
            return
        }
        XCTAssertEqual(
            sqlite3_exec(
                database,
                """
                PRAGMA foreign_keys=OFF;
                DROP TABLE heart_rate_sample;
                DROP TABLE whoop_latest_heart_rate;
                DROP TABLE whoop_decode_failure;
                DROP TABLE whoop_ppg_packet;
                CREATE TABLE heart_rate_sample (
                    id TEXT PRIMARY KEY,
                    source_packet_id TEXT NOT NULL,
                    received_at REAL NOT NULL,
                    device_timestamp INTEGER,
                    heart_rate INTEGER NOT NULL,
                    rr_intervals_json TEXT NOT NULL,
                    source TEXT NOT NULL,
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                );
                CREATE INDEX heart_rate_sample_received_at
                    ON heart_rate_sample(received_at);
                CREATE INDEX heart_rate_sample_source_time
                    ON heart_rate_sample(source, device_timestamp, received_at);
                CREATE INDEX heart_rate_sample_source_received
                    ON heart_rate_sample(source, received_at);
                CREATE TABLE whoop_decode_result (
                    source_packet_id TEXT NOT NULL,
                    decoder_version INTEGER NOT NULL,
                    protocol_version INTEGER,
                    stream TEXT NOT NULL,
                    status TEXT NOT NULL,
                    error TEXT,
                    decoded_at REAL NOT NULL,
                    PRIMARY KEY(source_packet_id, decoder_version),
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                );
                CREATE INDEX whoop_decode_result_status
                    ON whoop_decode_result(decoder_version, status);
                CREATE TABLE whoop_ppg_packet (
                    source_packet_id TEXT PRIMARY KEY,
                    sample_at REAL NOT NULL,
                    channel INTEGER NOT NULL CHECK(channel BETWEEN 1 AND 255),
                    sample_rate_hz REAL NOT NULL,
                    samples_i16_le BLOB NOT NULL,
                    FOREIGN KEY(source_packet_id) REFERENCES whoop_raw_packet(id)
                );
                CREATE INDEX whoop_ppg_packet_sample_at
                    ON whoop_ppg_packet(sample_at, channel);
                INSERT INTO whoop_raw_packet
                    (id, received_at, delivery_sequence, peripheral_id,
                     characteristic_uuid, frame_type, crc_valid, payload)
                VALUES
                    ('p1', 100, 1, 'strap', 'FD4B0003', 40, 1, X'01'),
                    ('p2', 200, 2, 'strap', 'FD4B0003', 40, 1, X'02');
                INSERT INTO heart_rate_sample
                    (id, source_packet_id, received_at, device_timestamp,
                     heart_rate, rr_intervals_json, source)
                VALUES
                    ('p1', 'p1', 100, 100, 60, '[]', 'whoop5_type40'),
                    ('p2', 'p2', 200, 200, 61, '[900]', 'whoop5_type40');
                INSERT INTO whoop_decode_result
                    (source_packet_id, decoder_version, protocol_version,
                     stream, status, error, decoded_at)
                VALUES
                    ('p1', 2, 26, 'optical_ppg', 'decoded', NULL, 100),
                    ('p2', 3, 99, 'historical_unknown', 'unsupported', 'fixture', 200);
                INSERT INTO whoop_ppg_packet
                    (source_packet_id, sample_at, channel, sample_rate_hz, samples_i16_le)
                VALUES ('p1', 100, 1, 24, X'0102');
                PRAGMA user_version=9;
                """,
                nil,
                nil,
                nil
            ), SQLITE_OK)
        sqlite3_close(database)

        do {
            let store = WhoopStore(databaseURL: databaseURL, runBackgroundDecoding: false)
            store.shutdownForTesting()
        }

        var migrated: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &migrated, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let migrated { sqlite3_close(migrated) } }
        XCTAssertEqual(scalarInt(migrated, sql: "PRAGMA user_version"), 10)
        XCTAssertEqual(scalarInt(migrated, sql: "PRAGMA freelist_count"), 0)
        XCTAssertEqual(scalarInt(migrated, sql: "SELECT COUNT(*) FROM heart_rate_sample"), 1)
        XCTAssertEqual(
            scalarInt(migrated, sql: "SELECT COUNT(*) FROM heart_rate_sample WHERE rr_intervals_json='[]'"),
            0
        )
        XCTAssertEqual(
            scalarInt(migrated, sql: "SELECT heart_rate FROM whoop_latest_heart_rate WHERE singleton=1"),
            61
        )
        XCTAssertEqual(scalarInt(migrated, sql: "SELECT COUNT(*) FROM whoop_decode_failure"), 1)
        XCTAssertEqual(
            scalarInt(migrated, sql: "SELECT decoder_version FROM whoop_ppg_packet WHERE source_packet_id='p1'"),
            2
        )
        XCTAssertEqual(
            scalarText(migrated, sql: "SELECT hex(samples_i16_le) FROM whoop_ppg_packet WHERE source_packet_id='p1'"),
            "0102"
        )
        XCTAssertEqual(
            scalarInt(
                migrated,
                sql:
                    "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='whoop_decode_result'"
            ), 0)
        XCTAssertEqual(scalarText(migrated, sql: "PRAGMA foreign_key_check"), nil)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(
                    "migration-backups/sleep-v9-before-v10.sqlite3"
                ).path
            ))
    }

    func testMigrationBackupPruningKeepsExactRollbackPointAndUnrelatedFiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let retained = directory.appendingPathComponent("sleep-v9-before-v10.sqlite3")
        let old = directory.appendingPathComponent("sleep-v8-before-v9.sqlite3")
        let unrelated = directory.appendingPathComponent("manual-recovery.sqlite3")
        for url in [retained, old, unrelated, URL(fileURLWithPath: old.path + "-wal")] {
            try Data("synthetic".utf8).write(to: url)
        }

        WhoopStore.pruneMigrationBackups(in: directory, keeping: retained)

        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path + "-wal"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}
