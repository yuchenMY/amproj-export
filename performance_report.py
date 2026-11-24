"""Summarize a downloaded Beta performance-ticket attachment without executing it."""
import argparse
import json
import math
from pathlib import Path

MAX_BYTES = 512 * 1024


def number(value):
    return float(value) if isinstance(value, (int, float)) and math.isfinite(value) else 0.0


def summarize(report):
    if not isinstance(report, dict) or report.get("kind") != "performance" or report.get("schema") != 1:
        raise ValueError("Unsupported performance report")
    events = report.get("events", [])
    if not isinstance(events, list) or any(not isinstance(event, dict) for event in events):
        raise ValueError("Invalid event list")
    events = sorted(events, key=lambda event: number(event.get("t_ms")))
    stalls, slow, samples = [], [], []
    for event in events:
        fields = event.get("fields")
        if not isinstance(fields, dict):
            continue
        kind = event.get("event")
        if kind in ("main_queue.stalled", "main_queue.recovered"):
            stalls.append({
                "at_ms": number(event.get("t_ms")), "event": kind,
                "delay_ms": max(number(fields.get("pending_ms")), number(fields.get("delay_ms"))),
            })
        if kind == "plugin.slow_span":
            slow.append({
                "at_ms": number(event.get("t_ms")), "name": str(fields.get("name", ""))[:96],
                "elapsed_ms": number(fields.get("elapsed_ms")),
            })
        if kind in ("performance.sample", "capture.stopped"):
            samples.append(fields)
    return {
        "capture_id": report.get("capture_id"),
        "environment": report.get("environment", {}),
        "duration_seconds": number(report.get("duration_ms")) / 1000,
        "finish_reason": report.get("finish_reason"),
        "events_dropped": number(report.get("events_dropped")),
        "max_main_queue_delay_ms": max(
            [entry["delay_ms"] for entry in stalls]
            + [number(sample.get("main_queue_pending_ms")) for sample in samples] + [0]
        ),
        "max_display_link_gap_ms": max([number(sample.get("display_link_max_gap_ms")) for sample in samples] + [0]),
        "peak_memory_mib": max([number(sample.get("memory_bytes")) for sample in samples] + [0]) / (1024 * 1024),
        "main_queue_events": stalls,
        "slow_spans": sorted(slow, key=lambda entry: entry["elapsed_ms"], reverse=True)[:20],
        "measurement_notes": report.get("measurement_notes"),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("attachment", type=Path)
    args = parser.parse_args()
    if args.attachment.stat().st_size > MAX_BYTES:
        parser.error("Attachment exceeds 512 KiB")
    try:
        result = summarize(json.loads(args.attachment.read_text(encoding="utf-8")))
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
