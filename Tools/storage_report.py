#!/usr/bin/env python3
"""Validate and summarize bounded WHOOP storage telemetry."""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import sys
import tempfile
from collections.abc import Iterable, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from itertools import pairwise
from pathlib import Path
from typing import cast

from phone_shipping_core import BUNDLE_IDENTIFIER, Device, ShippingError, choose_device, load_json
from phone_shipping_environment import CommandRunner, list_devices

MINIMUM_EVIDENCE_SECONDS = 72 * 60 * 60
STRONGEST_EVIDENCE_SECONDS = 7 * 24 * 60 * 60
MINIMUM_DAILY_SNAPSHOTS = 4
LATENCY_BUCKET_UPPER_MS = (0.5, 1.0, 2.0, 5.0, 10.0, 25.0, 50.0, 100.0, math.inf)
LATENCY_PERCENTILES = (0.5, 0.95, 0.99)


class ReportError(ValueError):
    """Raised when a telemetry document cannot support a trustworthy report."""


@dataclass(frozen=True)
class Snapshot:
    captured_at: float
    schema_version: int
    source_commit: str
    used_database_bytes: int
    unique_packets: int
    raw_payload_bytes: int
    derived_rows: dict[str, int]
    wal_bytes: int
    checkpoint_result: int
    wal_log_frames: int
    wal_checkpointed_frames: int
    checkpoint_nanoseconds: int
    snapshot_collection_nanoseconds: int
    persistence_failure_count: int
    census_failure_count: int
    frame_retries: dict[str, tuple[int, int, int]]
    ingestion: dict[str, object]


def _mapping(value: object, context: str) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ReportError(f"{context} must be an object.")
    return cast(dict[str, object], value)


def _sequence(value: object, context: str) -> list[object]:
    if not isinstance(value, list):
        raise ReportError(f"{context} must be an array.")
    return cast(list[object], value)


def _number(value: object, context: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ReportError(f"{context} must be a finite number.")
    return float(value)


def _string(value: object, context: str) -> str:
    if not isinstance(value, str) or not value:
        raise ReportError(f"{context} must be a non-empty string.")
    return value


def _integer(value: object, context: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ReportError(f"{context} must be an integer.")
    return value


def _nonnegative_integer(value: object, context: str) -> int:
    result = _integer(value, context)
    if result < 0:
        raise ReportError(f"{context} must not be negative.")
    return result


def _field(mapping: dict[str, object], name: str, context: str) -> object:
    if name not in mapping:
        raise ReportError(f"{context} is missing {name}.")
    return mapping[name]


def _parse_derived(value: object, context: str) -> dict[str, int]:
    raw = _mapping(value, context)
    return {
        table: _nonnegative_integer(count, f"{context}.{table}") for table, count in raw.items()
    }


def _parse_frame_retries(value: object, context: str) -> dict[str, tuple[int, int, int]]:
    result: dict[str, tuple[int, int, int]] = {}
    for index, item in enumerate(_sequence(value, context)):
        row_context = f"{context}[{index}]"
        row = _mapping(item, row_context)
        frame_type = _string(_field(row, "frameType", row_context), f"{row_context}.frameType")
        if frame_type in result:
            raise ReportError(f"{context} contains duplicate frame type {frame_type}.")
        result[frame_type] = (
            _nonnegative_integer(
                _field(row, "allHistoricalUniquePackets", row_context),
                f"{row_context}.allHistoricalUniquePackets",
            ),
            _nonnegative_integer(
                _field(row, "retryEligibleUniquePackets", row_context),
                f"{row_context}.retryEligibleUniquePackets",
            ),
            _nonnegative_integer(_field(row, "retries", row_context), f"{row_context}.retries"),
        )
    return result


def _parse_ingestion(value: object, context: str) -> dict[str, object]:
    ingestion = _mapping(value, context)
    delivery_count = _nonnegative_integer(
        _field(ingestion, "deliveryCount", context), f"{context}.deliveryCount"
    )
    outcomes = {
        name: _nonnegative_integer(_field(ingestion, name, context), f"{context}.{name}")
        for name in ("uniqueCount", "retryCount", "failedCount")
    }
    if sum(outcomes.values()) != delivery_count:
        raise ReportError(f"{context} outcome counts do not equal deliveryCount.")
    for name in ("transactionLatencyBucketCounts", "queueWaitBucketCounts"):
        buckets = _sequence(_field(ingestion, name, context), f"{context}.{name}")
        if len(buckets) != len(LATENCY_BUCKET_UPPER_MS):
            raise ReportError(f"{context}.{name} must contain 9 buckets.")
        bucket_total = sum(
            _nonnegative_integer(count, f"{context}.{name}[{index}]")
            for index, count in enumerate(buckets)
        )
        if bucket_total != delivery_count:
            raise ReportError(f"{context}.{name} does not equal deliveryCount.")
    frames = _sequence(_field(ingestion, "frameOutcomes", context), f"{context}.frameOutcomes")
    if len(frames) != 257:
        raise ReportError(f"{context}.frameOutcomes must contain 257 entries.")
    frame_totals = {"uniqueDeliveries": 0, "suppressedRetries": 0, "failedDeliveries": 0}
    for index, value in enumerate(frames):
        frame = _mapping(value, f"{context}.frameOutcomes[{index}]")
        for name in frame_totals:
            frame_totals[name] += _nonnegative_integer(
                _field(frame, name, context), f"{context}.frameOutcomes[{index}].{name}"
            )
    if list(frame_totals.values()) != [
        outcomes["uniqueCount"],
        outcomes["retryCount"],
        outcomes["failedCount"],
    ]:
        raise ReportError(f"{context} frame outcome totals do not match aggregate outcomes.")
    return ingestion


def _parse_snapshot(value: object, index: int) -> Snapshot:
    context = f"snapshots[{index}]"
    raw = _mapping(value, context)
    page_size = _nonnegative_integer(_field(raw, "pageSize", context), f"{context}.pageSize")
    page_count = _nonnegative_integer(_field(raw, "pageCount", context), f"{context}.pageCount")
    freelist = _nonnegative_integer(
        _field(raw, "freelistPages", context), f"{context}.freelistPages"
    )
    if freelist > page_count:
        raise ReportError(f"{context}.freelistPages exceeds pageCount.")
    calculated_used = (page_count - freelist) * page_size
    used = _nonnegative_integer(
        raw.get("usedDatabaseBytes", calculated_used), f"{context}.usedDatabaseBytes"
    )
    if used != calculated_used:
        raise ReportError(
            f"{context}.usedDatabaseBytes does not match pageSize/pageCount/freelistPages."
        )
    return Snapshot(
        captured_at=_number(_field(raw, "capturedAt", context), f"{context}.capturedAt"),
        schema_version=_nonnegative_integer(
            _field(raw, "schemaVersion", context), f"{context}.schemaVersion"
        ),
        source_commit=_string(_field(raw, "sourceCommit", context), f"{context}.sourceCommit"),
        used_database_bytes=used,
        unique_packets=_nonnegative_integer(
            _field(raw, "uniquePackets", context), f"{context}.uniquePackets"
        ),
        raw_payload_bytes=_nonnegative_integer(
            _field(raw, "rawPayloadBytes", context), f"{context}.rawPayloadBytes"
        ),
        derived_rows=_parse_derived(
            _field(raw, "derivedTableRows", context), f"{context}.derivedTableRows"
        ),
        wal_bytes=_nonnegative_integer(_field(raw, "walBytes", context), f"{context}.walBytes"),
        checkpoint_result=_integer(
            _field(raw, "passiveCheckpointResult", context),
            f"{context}.passiveCheckpointResult",
        ),
        wal_log_frames=_integer(_field(raw, "walLogFrames", context), f"{context}.walLogFrames"),
        wal_checkpointed_frames=_integer(
            _field(raw, "walCheckpointedFrames", context),
            f"{context}.walCheckpointedFrames",
        ),
        checkpoint_nanoseconds=_nonnegative_integer(
            _field(raw, "passiveCheckpointNanoseconds", context),
            f"{context}.passiveCheckpointNanoseconds",
        ),
        snapshot_collection_nanoseconds=_nonnegative_integer(
            raw.get("snapshotCollectionNanoseconds", 0),
            f"{context}.snapshotCollectionNanoseconds",
        ),
        persistence_failure_count=_nonnegative_integer(
            _field(raw, "persistenceFailureCount", context),
            f"{context}.persistenceFailureCount",
        ),
        census_failure_count=_nonnegative_integer(
            _field(raw, "censusFailureCount", context), f"{context}.censusFailureCount"
        ),
        frame_retries=_parse_frame_retries(
            _field(raw, "frameRetries", context), f"{context}.frameRetries"
        ),
        ingestion=_parse_ingestion(_field(raw, "ingestion", context), f"{context}.ingestion"),
    )


def _validate_monotonic(snapshots: Sequence[Snapshot]) -> None:
    schema_versions = {snapshot.schema_version for snapshot in snapshots}
    if len(schema_versions) != 1 or not schema_versions <= {10, 11}:
        raise ReportError(
            f"An evidence window requires one supported schema (10 or 11), not {sorted(schema_versions)}."
        )
    source_commits = {snapshot.source_commit for snapshot in snapshots}
    if len(source_commits) != 1:
        raise ReportError("All snapshots must contain one source commit.")
    source_commit = next(iter(source_commits))
    if len(source_commit) != 40 or any(
        character not in "0123456789abcdef" for character in source_commit
    ):
        raise ReportError("Snapshots must contain the exact 40-character lowercase source SHA.")
    for index, (previous, current) in enumerate(pairwise(snapshots), 1):
        if current.captured_at <= previous.captured_at:
            raise ReportError(f"snapshots[{index}].capturedAt is not strictly increasing.")
        for name, old, new in (
            ("uniquePackets", previous.unique_packets, current.unique_packets),
            ("rawPayloadBytes", previous.raw_payload_bytes, current.raw_payload_bytes),
            (
                "persistenceFailureCount",
                previous.persistence_failure_count,
                current.persistence_failure_count,
            ),
            ("censusFailureCount", previous.census_failure_count, current.census_failure_count),
        ):
            if new < old:
                raise ReportError(f"snapshots[{index}].{name} decreased from {old} to {new}.")
        for table in set(previous.derived_rows).intersection(current.derived_rows):
            if current.derived_rows[table] < previous.derived_rows[table]:
                raise ReportError(
                    f"snapshots[{index}].derivedTableRows.{table} decreased from "
                    f"{previous.derived_rows[table]} to {current.derived_rows[table]}."
                )
        for frame_type in set(previous.frame_retries).union(current.frame_retries):
            previous_frame = previous.frame_retries.get(frame_type, (0, 0, 0))
            current_frame = current.frame_retries.get(frame_type, (0, 0, 0))
            if any(current_frame[position] < previous_frame[position] for position in range(3)):
                raise ReportError(
                    f"snapshots[{index}].frameRetries decreased for frame {frame_type}."
                )


def _sum_integer(mapping: dict[str, object], name: str, context: str) -> int:
    return _nonnegative_integer(mapping.get(name, 0), f"{context}.{name}")


def _histogram(ingestions: Iterable[dict[str, object]], name: str) -> list[int]:
    total = [0] * len(LATENCY_BUCKET_UPPER_MS)
    for index, ingestion in enumerate(ingestions):
        raw = _sequence(ingestion.get(name, []), f"ingestion[{index}].{name}")
        if len(raw) != len(total):
            raise ReportError(f"ingestion[{index}].{name} must contain {len(total)} buckets.")
        for bucket, value in enumerate(raw):
            total[bucket] += _nonnegative_integer(value, f"ingestion[{index}].{name}[{bucket}]")
    return total


def _estimated_percentile(histogram: Sequence[int], percentile: float) -> float | str | None:
    count = sum(histogram)
    if count == 0:
        return None
    target = math.ceil(count * percentile)
    cumulative = 0
    for upper, bucket_count in zip(LATENCY_BUCKET_UPPER_MS, histogram, strict=True):
        cumulative += bucket_count
        if cumulative >= target:
            return ">100" if math.isinf(upper) else upper
    raise AssertionError("A non-empty histogram must contain its percentile.")


def _latency_summary(ingestions: Sequence[dict[str, object]], queue: bool) -> dict[str, object]:
    histogram_name = "queueWaitBucketCounts" if queue else "transactionLatencyBucketCounts"
    total_name = "queueWaitTotalNanoseconds" if queue else "totalNanoseconds"
    maximum_name = "queueWaitMaximumNanoseconds" if queue else "maximumNanoseconds"
    histogram = _histogram(ingestions, histogram_name)
    sample_count = sum(histogram)
    total_nanoseconds = sum(
        _sum_integer(item, total_name, f"ingestion[{index}]")
        for index, item in enumerate(ingestions)
    )
    maximum_nanoseconds = max(
        (
            _sum_integer(item, maximum_name, f"ingestion[{index}]")
            for index, item in enumerate(ingestions)
        ),
        default=0,
    )
    percentiles = {
        f"p{int(percentile * 100)}UpperBoundMs": _estimated_percentile(histogram, percentile)
        for percentile in LATENCY_PERCENTILES
    }
    return {
        "samples": sample_count,
        "meanMs": total_nanoseconds / sample_count / 1_000_000 if sample_count else None,
        "maximumMs": maximum_nanoseconds / 1_000_000 if sample_count else None,
        **percentiles,
        "bucketCounts": histogram,
    }


def _retry_summary(ingestions: Sequence[dict[str, object]]) -> list[dict[str, object]]:
    totals: dict[int, dict[str, int]] = {}
    for window_index, ingestion in enumerate(ingestions):
        outcomes = _sequence(
            ingestion.get("frameOutcomes", []), f"ingestion[{window_index}].frameOutcomes"
        )
        if len(outcomes) != 257:
            raise ReportError(f"ingestion[{window_index}].frameOutcomes must contain 257 entries.")
        for frame_index, raw_outcome in enumerate(outcomes):
            outcome = _mapping(
                raw_outcome, f"ingestion[{window_index}].frameOutcomes[{frame_index}]"
            )
            values = totals.setdefault(
                frame_index,
                {"unique": 0, "retries": 0, "failed": 0, "disabled": 0, "payload": 0},
            )
            for destination, source in (
                ("unique", "uniqueDeliveries"),
                ("retries", "suppressedRetries"),
                ("failed", "failedDeliveries"),
                ("disabled", "retryDetectionDisabled"),
                ("payload", "payloadBytes"),
            ):
                values[destination] += _sum_integer(
                    outcome,
                    source,
                    f"ingestion[{window_index}].frameOutcomes[{frame_index}]",
                )
    result: list[dict[str, object]] = []
    for frame_index, values in sorted(totals.items()):
        deliveries = values["unique"] + values["retries"]
        if deliveries == 0 and values["failed"] == 0:
            continue
        ratio: float | None = (
            values["retries"] / deliveries if deliveries and values["disabled"] == 0 else None
        )
        result.append(
            {
                "frameType": "unknown" if frame_index == 256 else str(frame_index),
                "uniqueDeliveries": values["unique"],
                "suppressedRetries": values["retries"],
                "failedDeliveries": values["failed"],
                "retryDetectionDisabled": values["disabled"],
                "payloadBytes": values["payload"],
                "retryRatio": ratio,
                "ratioIncludesDetectionDisabledTraffic": values["disabled"] > 0,
            }
        )
    return result


def _percentile(values: Sequence[int], percentile: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * percentile) - 1)
    return float(ordered[index])


def build_report(document: object) -> dict[str, object]:
    root = _mapping(document, "telemetry")
    if _integer(_field(root, "formatVersion", "telemetry"), "telemetry.formatVersion") != 1:
        raise ReportError("telemetry.formatVersion must be 1.")
    snapshots = [
        _parse_snapshot(value, index)
        for index, value in enumerate(
            _sequence(_field(root, "snapshots", "telemetry"), "snapshots")
        )
    ]
    if not snapshots:
        raise ReportError("telemetry must contain at least one snapshot.")
    _validate_monotonic(snapshots)

    first = snapshots[0]
    last = snapshots[-1]
    observed_seconds = max(0.0, last.captured_at - first.captured_at)
    if observed_seconds >= STRONGEST_EVIDENCE_SECONDS and len(snapshots) >= 8:
        evidence_level = "strongest"
    elif observed_seconds >= MINIMUM_EVIDENCE_SECONDS and len(snapshots) >= MINIMUM_DAILY_SNAPSHOTS:
        evidence_level = "sufficient"
    else:
        evidence_level = "collecting"

    intervals: list[dict[str, object]] = []
    for previous, current in pairwise(snapshots):
        unique_delta = current.unique_packets - previous.unique_packets
        used_delta = current.used_database_bytes - previous.used_database_bytes
        intervals.append(
            {
                "start": _iso_time(previous.captured_at),
                "end": _iso_time(current.captured_at),
                "hours": (current.captured_at - previous.captured_at) / 3600,
                "usedDatabaseBytesDelta": used_delta,
                "uniquePacketsDelta": unique_delta,
                "bytesPerUniquePacket": used_delta / unique_delta if unique_delta else None,
            }
        )
    unique_delta = last.unique_packets - first.unique_packets
    used_delta = last.used_database_bytes - first.used_database_bytes
    raw_payload_delta = last.raw_payload_bytes - first.raw_payload_bytes

    derived: list[dict[str, object]] = []
    for table in sorted(set(first.derived_rows).union(last.derived_rows)):
        start = first.derived_rows.get(table)
        end = last.derived_rows.get(table)
        if start is None or end is None:
            continue
        delta = end - start
        derived.append(
            {
                "table": table,
                "rowsDelta": delta,
                "rowsPerDay": delta / observed_seconds * 86_400 if observed_seconds else None,
                "rowsPerUniquePacket": delta / unique_delta if unique_delta else None,
            }
        )

    interval_ingestions = [snapshot.ingestion for snapshot in snapshots[1:]]
    file_samples = [
        _mapping(value, f"fileSamples[{index}]")
        for index, value in enumerate(_sequence(root.get("fileSamples", []), "fileSamples"))
    ]
    file_sample_wal = [
        _nonnegative_integer(sample.get("walBytes", 0), f"fileSamples[{index}].walBytes")
        for index, sample in enumerate(file_samples)
    ]
    checkpoint_failures = sum(snapshot.checkpoint_result != 0 for snapshot in snapshots)
    available_log_frames = [
        snapshot.wal_log_frames for snapshot in snapshots if snapshot.wal_log_frames >= 0
    ]
    available_checkpointed_frames = [
        snapshot.wal_checkpointed_frames
        for snapshot in snapshots
        if snapshot.wal_checkpointed_frames >= 0
    ]
    interval_unique_deliveries = sum(
        _sum_integer(item, "uniqueCount", f"ingestion[{index}]")
        for index, item in enumerate(interval_ingestions)
    )
    ingestion_coverage = interval_unique_deliveries / unique_delta if unique_delta else None
    persistence_failures = last.persistence_failure_count - first.persistence_failure_count
    census_failures = last.census_failure_count - first.census_failure_count
    coverage_valid = ingestion_coverage is None or 0.95 <= ingestion_coverage <= 1.05
    if unique_delta == 0:
        evidence_level = "no-traffic"
    elif evidence_level != "collecting" and (
        persistence_failures > 0 or checkpoint_failures > 0 or not coverage_valid
    ):
        evidence_level = "degraded"

    replay_retry_rows: list[dict[str, object]] = []
    for frame_type in sorted(set(first.frame_retries).union(last.frame_retries)):
        old = first.frame_retries.get(frame_type, (0, 0, 0))
        new = last.frame_retries.get(frame_type, (0, 0, 0))
        deltas = tuple(new[index] - old[index] for index in range(3))
        if any(value < 0 for value in deltas):
            raise ReportError(f"Replay-ledger counters decreased for frame {frame_type}.")
        all_unique, eligible_unique, retries = deltas
        deliveries = eligible_unique + retries
        if all_unique or deliveries:
            replay_retry_rows.append(
                {
                    "frameType": frame_type,
                    "allHistoricalUniqueDelta": all_unique,
                    "retryEligibleUniqueDelta": eligible_unique,
                    "retriesDelta": retries,
                    "retryRatio": retries / deliveries if deliveries else None,
                }
            )
    return {
        "evidence": {
            "status": evidence_level,
            "snapshotCount": len(snapshots),
            "observedHours": observed_seconds / 3600,
            "minimumHours": MINIMUM_EVIDENCE_SECONDS / 3600,
            "minimumSnapshots": MINIMUM_DAILY_SNAPSHOTS,
            "sourceCommit": first.source_commit,
            "schemaVersion": first.schema_version,
            "ingestionCoverageRatio": ingestion_coverage,
            "persistenceFailures": persistence_failures,
            "recoveredCensusFailures": census_failures,
            "coverageValid": coverage_valid,
        },
        "period": {"start": _iso_time(first.captured_at), "end": _iso_time(last.captured_at)},
        "amplification": {
            "usedDatabaseBytesDelta": used_delta,
            "uniquePacketsDelta": unique_delta,
            "bytesPerUniquePacket": used_delta / unique_delta if unique_delta else None,
            "rawPayloadBytesDelta": raw_payload_delta,
            "usedBytesPerRawPayloadByte": (
                used_delta / raw_payload_delta if raw_payload_delta else None
            ),
        },
        "intervals": intervals,
        "retryByFrame": _retry_summary(interval_ingestions),
        "replayLedgerRetryByFrame": replay_retry_rows,
        "transactionLatency": _latency_summary(interval_ingestions, queue=False),
        "queueWaitLatency": _latency_summary(interval_ingestions, queue=True),
        "wal": {
            "snapshotMaximumBytes": max((snapshot.wal_bytes for snapshot in snapshots), default=0),
            "fileSampleMaximumBytes": max(file_sample_wal, default=0),
            "fileSampleP95Bytes": _percentile(file_sample_wal, 0.95),
            "maximumLogFrames": max(available_log_frames, default=None),
            "maximumCheckpointedFrames": max(available_checkpointed_frames, default=None),
            "maximumCheckpointMs": max(
                (snapshot.checkpoint_nanoseconds for snapshot in snapshots), default=0
            )
            / 1_000_000,
            "maximumCensusMs": max(
                (snapshot.snapshot_collection_nanoseconds for snapshot in snapshots), default=0
            )
            / 1_000_000,
            "checkpointFailures": checkpoint_failures,
        },
        "derivedTableGrowth": derived,
    }


def _iso_time(timestamp: float) -> str:
    return (
        datetime.fromtimestamp(timestamp, UTC).isoformat(timespec="seconds").replace("+00:00", "Z")
    )


def _format_number(value: object, digits: int = 2) -> str:
    if value is None:
        return "n/a"
    if isinstance(value, str):
        return value
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return f"{value:,.{digits}f}"
    raise TypeError(f"Cannot format {value!r} as a number.")


def _percentile_phrase(value: object) -> str:
    if isinstance(value, str):
        return f"{value} ms"
    return f"≤ {_format_number(value)} ms"


def render_markdown(report: dict[str, object]) -> str:
    evidence = _mapping(report["evidence"], "report.evidence")
    period = _mapping(report["period"], "report.period")
    amplification = _mapping(report["amplification"], "report.amplification")
    transaction = _mapping(report["transactionLatency"], "report.transactionLatency")
    queue = _mapping(report["queueWaitLatency"], "report.queueWaitLatency")
    wal = _mapping(report["wal"], "report.wal")
    lines = [
        "# WHOOP storage telemetry",
        "",
        f"Status: **{evidence['status']}** — {evidence['snapshotCount']} snapshots over "
        f"{_format_number(evidence['observedHours'], 1)} hours ({period['start']} to {period['end']}).",
        f"Schema/build: v{evidence['schemaVersion']} at {evidence['sourceCommit']}; "
        f"ingestion coverage {_format_number(evidence['ingestionCoverageRatio'])}x; "
        f"persistence failures {evidence['persistenceFailures']}; "
        f"recovered census failures {evidence['recoveredCensusFailures']}.",
        "",
        "## Storage amplification",
        "",
        f"- Used database growth: {_format_number(amplification['usedDatabaseBytesDelta'], 0)} bytes",
        f"- Unique packet growth: {_format_number(amplification['uniquePacketsDelta'], 0)}",
        f"- Bytes per unique packet: {_format_number(amplification['bytesPerUniquePacket'])}",
        f"- Raw payload growth: {_format_number(amplification['rawPayloadBytesDelta'], 0)} bytes",
        f"- Used bytes per raw payload byte: "
        f"{_format_number(amplification['usedBytesPerRawPayloadByte'])}x",
        "",
        "## Latency",
        "",
        f"- Transaction: mean {_format_number(transaction['meanMs'])} ms, "
        f"p50 {_percentile_phrase(transaction['p50UpperBoundMs'])}, "
        f"p95 {_percentile_phrase(transaction['p95UpperBoundMs'])}, "
        f"p99 {_percentile_phrase(transaction['p99UpperBoundMs'])}, "
        f"max {_format_number(transaction['maximumMs'])} ms",
        f"- Queue wait: mean {_format_number(queue['meanMs'])} ms, "
        f"p50 {_percentile_phrase(queue['p50UpperBoundMs'])}, "
        f"p95 {_percentile_phrase(queue['p95UpperBoundMs'])}, "
        f"p99 {_percentile_phrase(queue['p99UpperBoundMs'])}, "
        f"max {_format_number(queue['maximumMs'])} ms",
        "",
        "## WAL and checkpoints",
        "",
        f"- Maximum sampled WAL: {_format_number(wal['fileSampleMaximumBytes'], 0)} bytes",
        f"- P95 sampled WAL: {_format_number(wal['fileSampleP95Bytes'], 0)} bytes",
        f"- Maximum log/checkpointed frames: {wal['maximumLogFrames']} / "
        f"{wal['maximumCheckpointedFrames']}",
        f"- Maximum passive-checkpoint time: {_format_number(wal['maximumCheckpointMs'])} ms",
        f"- Maximum full-census time: {_format_number(wal['maximumCensusMs'])} ms",
        f"- Checkpoint failures: {wal['checkpointFailures']}",
        "",
        "## Retry ratio by frame",
        "",
        "| Frame | Unique | Retries | Retry ratio | Detection-disabled |",
        "| --- | ---: | ---: | ---: | ---: |",
    ]
    for raw_row in _sequence(report["retryByFrame"], "report.retryByFrame"):
        row = _mapping(raw_row, "retry row")
        ratio = row["retryRatio"]
        ratio_text = "n/a" if ratio is None else f"{float(cast(float, ratio)):.2%}"
        lines.append(
            f"| {row['frameType']} | {row['uniqueDeliveries']} | {row['suppressedRetries']} | "
            f"{ratio_text} | {row['retryDetectionDisabled']} |"
        )
    lines.extend(
        [
            "",
            "## Replay-ledger retry delta",
            "",
            "| Frame | Eligible unique | Retries | Retry ratio | All unique |",
            "| --- | ---: | ---: | ---: | ---: |",
        ]
    )
    for raw_row in _sequence(report["replayLedgerRetryByFrame"], "report.replayLedgerRetryByFrame"):
        row = _mapping(raw_row, "replay retry row")
        ratio = row["retryRatio"]
        ratio_text = "n/a" if ratio is None else f"{float(cast(float, ratio)):.2%}"
        lines.append(
            f"| {row['frameType']} | {row['retryEligibleUniqueDelta']} | "
            f"{row['retriesDelta']} | {ratio_text} | {row['allHistoricalUniqueDelta']} |"
        )
    lines.extend(
        [
            "",
            "## Derived-table growth",
            "",
            "| Table | Rows | Rows/day | Rows/unique packet |",
            "| --- | ---: | ---: | ---: |",
        ]
    )
    for raw_row in _sequence(report["derivedTableGrowth"], "report.derivedTableGrowth"):
        row = _mapping(raw_row, "derived row")
        lines.append(
            f"| {row['table']} | {row['rowsDelta']} | {_format_number(row['rowsPerDay'])} | "
            f"{_format_number(row['rowsPerUniquePacket'], 4)} |"
        )
    return "\n".join(lines) + "\n"


def analyze_file(path: Path) -> dict[str, object]:
    try:
        document = load_json(path, "storage telemetry")
    except ShippingError as error:
        raise ReportError(str(error)) from error
    return build_report(document)


def collect_phone(
    output: Path,
    requested_device: str | None,
    runner: CommandRunner | None = None,
) -> tuple[Path, Device]:
    effective_runner = runner or CommandRunner()
    with tempfile.TemporaryDirectory(prefix="whoop-storage-collect-") as temporary:
        scratch = Path(temporary) / "scratch"
        payload = list_devices(effective_runner, scratch)
        device = choose_device(payload, requested_device)
        staging = Path(temporary) / "received"
        staging.mkdir()
        received_file = staging / "storage-telemetry-v1.json"
        effective_runner.devicectl_json(
            [
                "device",
                "copy",
                "from",
                "--device",
                device.identifier,
                "--domain-type",
                "appDataContainer",
                "--domain-identifier",
                BUNDLE_IDENTIFIER,
                "--source",
                "Library/Application Support/Sleep/storage-telemetry-v1.json",
                "--destination",
                str(received_file),
                "--timeout",
                "120",
            ],
            scratch,
            timeout=130,
        )
        candidates = list(staging.rglob("storage-telemetry-v1.json"))
        if len(candidates) != 1:
            raise ShippingError(
                "CoreDevice did not return exactly one storage-telemetry-v1.json file."
            )
        analyze_file(candidates[0])
        output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor, temporary_name = tempfile.mkstemp(prefix=f".{output.name}.", dir=output.parent)
        os.close(descriptor)
        temporary_output = Path(temporary_name)
        try:
            shutil.copyfile(candidates[0], temporary_output)
            temporary_output.chmod(0o600)
            os.replace(temporary_output, output)
        finally:
            temporary_output.unlink(missing_ok=True)
    return output, device


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    analyze = commands.add_parser("analyze", help="Validate and summarize a telemetry JSON file.")
    analyze.add_argument("telemetry", type=Path)
    analyze.add_argument("--format", choices=("markdown", "json"), default="markdown")
    collect = commands.add_parser(
        "collect-phone", help="Copy only the telemetry sidecar from a paired iPhone."
    )
    collect.add_argument("--output", type=Path, required=True)
    collect.add_argument("--device")
    return parser


def main(arguments: Sequence[str] | None = None) -> int:
    options = _parser().parse_args(arguments)
    try:
        if options.command == "analyze":
            report = analyze_file(options.telemetry)
            if options.format == "json":
                print(json.dumps(report, indent=2, sort_keys=True))
            else:
                print(render_markdown(report), end="")
        elif options.command == "collect-phone":
            output, device = collect_phone(options.output, options.device)
            print(f"Collected {output} from {device.name} ({device.udid}).")
        else:
            raise AssertionError(f"Unsupported command: {options.command}")
    except (ReportError, ShippingError, OSError) as error:
        print(f"storage-report: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
