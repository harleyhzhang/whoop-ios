from __future__ import annotations

import json
import stat
import subprocess
from pathlib import Path

import pytest
import storage_report
from phone_shipping_environment import CommandRunner


def frame_outcomes(*, unique: int = 0, retries: int = 0) -> list[dict[str, int]]:
    outcomes = [
        {
            "uniqueDeliveries": 0,
            "suppressedRetries": 0,
            "failedDeliveries": 0,
            "retryDetectionDisabled": 0,
            "payloadBytes": 0,
        }
        for _ in range(257)
    ]
    outcomes[47] = {
        "uniqueDeliveries": unique,
        "suppressedRetries": retries,
        "failedDeliveries": 1,
        "retryDetectionDisabled": 0,
        "payloadBytes": (unique + retries) * 80,
    }
    return outcomes


def ingestion(*, unique: int = 100, retries: int = 10) -> dict[str, object]:
    deliveries = unique + retries + 1
    return {
        "deliveryCount": deliveries,
        "uniqueCount": unique,
        "retryCount": retries,
        "failedCount": 1,
        "totalNanoseconds": deliveries * 2_000_000,
        "maximumNanoseconds": 8_000_000,
        "transactionLatencyBucketCounts": [0, 0, deliveries, 0, 0, 0, 0, 0, 0],
        "queueWaitTotalNanoseconds": deliveries * 1_000_000,
        "queueWaitMaximumNanoseconds": 4_000_000,
        "queueWaitBucketCounts": [0, deliveries, 0, 0, 0, 0, 0, 0, 0],
        "frameOutcomes": frame_outcomes(unique=unique, retries=retries),
    }


def snapshot(day: int, *, unique_packets: int | None = None) -> dict[str, object]:
    page_size = 4096
    page_count = 1_000 + day * 10
    return {
        "capturedAt": 1_800_000_000 + day * 86_400,
        "schemaVersion": 10,
        "sourceCommit": "a" * 40,
        "databaseBytes": page_count * page_size,
        "walBytes": day * 1_000,
        "sharedMemoryBytes": 32_768,
        "pageSize": page_size,
        "pageCount": page_count,
        "freelistPages": 0,
        "usedDatabaseBytes": page_count * page_size,
        "uniquePackets": unique_packets if unique_packets is not None else 1_000 + day * 100,
        "rawPayloadBytes": 75_000 + day * 7_500,
        "sourcePairCount": 4,
        "frameRetries": [
            {
                "frameType": "47",
                "allHistoricalUniquePackets": 1_000 + day * 100,
                "retryEligibleUniquePackets": 800 + day * 100,
                "retries": 80 + day * 10,
            }
        ],
        "derivedTableRows": {
            "heart_rate_sample": 200 + day * 20,
            "whoop_historical_sample": 400 + day * 50,
        },
        "walCheckpointSequenceBefore": day,
        "walCheckpointSequenceAfter": day,
        "passiveCheckpointResult": 0,
        "walLogFrames": 100 + day,
        "walCheckpointedFrames": 90 + day,
        "passiveCheckpointNanoseconds": 2_000_000 + day,
        "snapshotCollectionNanoseconds": 8_000_000 + day,
        "persistenceFailureCount": 0,
        "censusFailureCount": 0,
        "ingestion": ingestion(),
    }


def telemetry(days: list[int]) -> dict[str, object]:
    return {
        "formatVersion": 1,
        "updatedAt": 1_800_000_000 + days[-1] * 86_400,
        "snapshots": [snapshot(day) for day in days],
        "fileSamples": [
            {
                "capturedAt": 1_800_000_000 + day * 86_400,
                "databaseBytes": 4_096_000 + day * 40_960,
                "walBytes": day * 2_000,
                "sharedMemoryBytes": 32_768,
                "walCheckpointSequence": day,
            }
            for day in days
        ],
        "pendingIngestion": ingestion(unique=1, retries=0),
        "writeFailureCount": 0,
    }


def test_report_reaches_sufficient_gate_and_uses_interval_counters() -> None:
    report = storage_report.build_report(telemetry([0, 1, 2, 3]))

    assert report["evidence"] == {
        "status": "sufficient",
        "snapshotCount": 4,
        "observedHours": 72.0,
        "minimumHours": 72.0,
        "minimumSnapshots": 4,
        "sourceCommit": "a" * 40,
        "schemaVersion": 10,
        "ingestionCoverageRatio": 1.0,
        "persistenceFailures": 0,
        "recoveredCensusFailures": 0,
        "coverageValid": True,
    }
    amplification = report["amplification"]
    assert isinstance(amplification, dict)
    assert amplification["bytesPerUniquePacket"] == pytest.approx(409.6)
    assert amplification["usedBytesPerRawPayloadByte"] == pytest.approx(40_960 / 7_500)
    retries = report["retryByFrame"]
    assert isinstance(retries, list)
    assert retries[0]["frameType"] == "47"
    assert retries[0]["retryRatio"] == pytest.approx(10 / 110)
    transaction = report["transactionLatency"]
    assert isinstance(transaction, dict)
    assert transaction["meanMs"] == pytest.approx(2.0)
    assert transaction["p95UpperBoundMs"] == 2.0
    wal = report["wal"]
    assert isinstance(wal, dict)
    assert wal["maximumCensusMs"] == pytest.approx(8.000003)
    derived = report["derivedTableGrowth"]
    assert isinstance(derived, list)
    historical = next(row for row in derived if row["table"] == "whoop_historical_sample")
    assert historical["rowsDelta"] == 150


def test_report_is_collecting_before_gate_and_strongest_at_seven_days() -> None:
    collecting = storage_report.build_report(telemetry([0, 1, 2]))["evidence"]
    sparse = storage_report.build_report(telemetry([0, 3, 6, 7]))["evidence"]
    strongest = storage_report.build_report(telemetry([0, 1, 2, 3, 4, 5, 6, 7]))["evidence"]
    assert isinstance(collecting, dict)
    assert isinstance(sparse, dict)
    assert isinstance(strongest, dict)
    assert collecting["status"] == "collecting"
    assert sparse["status"] == "degraded"
    assert strongest["status"] == "strongest"


def test_report_degrades_sufficient_window_when_telemetry_is_incomplete() -> None:
    document = telemetry([0, 1, 2, 3])
    snapshots = document["snapshots"]
    assert isinstance(snapshots, list)
    last = snapshots[-1]
    assert isinstance(last, dict)
    last["persistenceFailureCount"] = 1
    evidence = storage_report.build_report(document)["evidence"]
    assert isinstance(evidence, dict)
    assert evidence["status"] == "degraded"


def test_report_rejects_mixed_schema_or_build_window() -> None:
    document = telemetry([0, 1, 2, 3])
    snapshots = document["snapshots"]
    assert isinstance(snapshots, list)
    changed = snapshots[2]
    assert isinstance(changed, dict)
    changed["sourceCommit"] = "different"
    with pytest.raises(storage_report.ReportError):
        storage_report.build_report(document)


def test_report_rejects_internally_inconsistent_ingestion() -> None:
    document = telemetry([0, 1, 2, 3])
    snapshots = document["snapshots"]
    assert isinstance(snapshots, list)
    changed = snapshots[2]
    assert isinstance(changed, dict)
    changed_ingestion = changed["ingestion"]
    assert isinstance(changed_ingestion, dict)
    changed_ingestion["frameOutcomes"] = []
    with pytest.raises(storage_report.ReportError, match="257"):
        storage_report.build_report(document)


def test_report_excludes_first_snapshot_ingestion_and_rejects_no_traffic() -> None:
    document = telemetry([0, 1, 2, 3])
    snapshots = document["snapshots"]
    assert isinstance(snapshots, list)
    first = snapshots[0]
    assert isinstance(first, dict)
    first["ingestion"] = ingestion(unique=1, retries=1_000)
    report = storage_report.build_report(document)
    retries = report["retryByFrame"]
    assert isinstance(retries, list)
    assert retries[0]["retryRatio"] == pytest.approx(10 / 110)
    latency = report["transactionLatency"]
    assert isinstance(latency, dict)
    assert latency["samples"] == 333

    no_traffic = telemetry([0, 1, 2, 3])
    no_traffic_snapshots = no_traffic["snapshots"]
    assert isinstance(no_traffic_snapshots, list)
    for item in no_traffic_snapshots:
        assert isinstance(item, dict)
        item["uniquePackets"] = 1_000
        item["rawPayloadBytes"] = 75_000
        item["ingestion"] = ingestion(unique=0, retries=0)
    evidence = storage_report.build_report(no_traffic)["evidence"]
    assert isinstance(evidence, dict)
    assert evidence["status"] == "no-traffic"


@pytest.mark.parametrize("failure", ["timestamp", "packets", "derived", "used"])
def test_report_rejects_nonmonotonic_or_internally_inconsistent_snapshots(
    failure: str,
) -> None:
    document = telemetry([0, 1, 2, 3])
    snapshots = document["snapshots"]
    assert isinstance(snapshots, list)
    target = snapshots[2]
    assert isinstance(target, dict)
    if failure == "timestamp":
        target["capturedAt"] = snapshots[1]["capturedAt"]
    elif failure == "packets":
        target["uniquePackets"] = 1
    elif failure == "derived":
        target["derivedTableRows"]["heart_rate_sample"] = 1
    else:
        target["usedDatabaseBytes"] = 1

    with pytest.raises(storage_report.ReportError):
        storage_report.build_report(document)


def test_markdown_and_json_cli_outputs(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    telemetry_path = tmp_path / "telemetry.json"
    telemetry_path.write_text(json.dumps(telemetry([0, 1, 2, 3])))

    assert storage_report.main(["analyze", str(telemetry_path)]) == 0
    assert "Status: **sufficient**" in capsys.readouterr().out
    assert storage_report.main(["analyze", str(telemetry_path), "--format", "json"]) == 0
    decoded = json.loads(capsys.readouterr().out)
    assert decoded["evidence"]["status"] == "sufficient"


def device_payload() -> object:
    return {
        "result": {
            "devices": [
                {
                    "identifier": "CORE-1",
                    "deviceProperties": {
                        "developerModeStatus": "enabled",
                        "name": "Primary iPhone",
                    },
                    "hardwareProperties": {
                        "deviceType": "iPhone",
                        "reality": "physical",
                        "udid": "UDID-1",
                    },
                    "connectionProperties": {
                        "pairingState": "paired",
                        "tunnelState": "connected",
                        "lastConnectionDate": "2026-09-12T20:00:00Z",
                    },
                }
            ]
        }
    }


class CollectRunner(CommandRunner):
    def __init__(self) -> None:
        super().__init__(verbose=False)
        self.calls: list[list[str]] = []

    def devicectl_json(
        self,
        arguments: list[str],
        scratch: Path,
        *,
        check: bool = True,
        timeout: int = 60,
    ) -> tuple[object | None, subprocess.CompletedProcess[str]]:
        del scratch, check, timeout
        self.calls.append(arguments)
        completed = subprocess.CompletedProcess(arguments, 0, "", "")
        if arguments[:2] == ["list", "devices"]:
            return device_payload(), completed
        assert arguments[:3] == ["device", "copy", "from"]
        destination = Path(arguments[arguments.index("--destination") + 1])
        (destination / "storage-telemetry-v1.json").write_text(json.dumps(telemetry([0, 1, 2, 3])))
        return {}, completed


def test_collect_phone_copies_only_valid_telemetry_atomically(tmp_path: Path) -> None:
    runner = CollectRunner()
    output = tmp_path / "collected.json"

    collected, device = storage_report.collect_phone(output, "UDID-1", runner)

    assert collected == output
    assert device.udid == "UDID-1"
    evidence = storage_report.analyze_file(output)["evidence"]
    assert isinstance(evidence, dict)
    assert evidence["status"] == "sufficient"
    assert stat.S_IMODE(output.stat().st_mode) == 0o600
    assert len(runner.calls) == 2
    copy_call = runner.calls[1]
    assert copy_call[copy_call.index("--source") + 1] == (
        "Library/Application Support/Sleep/storage-telemetry-v1.json"
    )
    assert "process" not in copy_call
    assert "install" not in copy_call
