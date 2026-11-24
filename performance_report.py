"""Summarize a downloaded Beta performance-ticket attachment without executing it."""
import argparse
from collections import Counter
import json
import math
from pathlib import Path

MAX_BYTES = 512 * 1024


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0.0
    try:
        return float(value) if math.isfinite(value) else 0.0
    except OverflowError:
        return 0.0


def peak_cpu(samples, key):
    values = []
    for sample in samples:
        value = sample.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            continue
        try:
            if math.isfinite(value) and value >= 0:
                values.append(float(value))
        except OverflowError:
            continue
    return max(values) if values else None


def summarize(report):
    if not isinstance(report, dict) or report.get("kind") != "performance" or report.get("schema") != 1:
        raise ValueError("Unsupported performance report")
    events = report.get("events", [])
    if not isinstance(events, list) or any(not isinstance(event, dict) for event in events):
        raise ValueError("Invalid event list")
    events = sorted(events, key=lambda event: number(event.get("t_ms")))
    stalls, slow, samples, thread_samples, capture_changes, disabled = [], [], [], [], [], []
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
        if kind == "main_thread.sample":
            thread_samples.append({"at_ms": number(event.get("t_ms")), **fields})
        if kind == "screen.capture_changed":
            capture_changes.append({"at_ms": number(event.get("t_ms")),
                                    "captured": fields.get("captured") if isinstance(fields.get("captured"), bool) else None})
        if kind == "main_thread.probe_disabled":
            disabled.append({"at_ms": number(event.get("t_ms")), **fields})
    locations = Counter()
    for sample in thread_samples:
        frames = sample.get("frames")
        if not isinstance(frames, list):
            continue
        for depth, frame in enumerate(frames[:20]):
            if isinstance(frame, dict) and frame.get("resolved") is True:
                locations[(str(sample.get("reason", ""))[:96], depth,
                           str(frame.get("image", ""))[:96], str(frame.get("uuid", ""))[:37],
                           number(frame.get("image_offset")), str(frame.get("symbol", ""))[:160],
                           number(frame.get("symbol_offset")))] += 1
    initial_capture = report.get("environment", {}).get("screen_captured") if isinstance(report.get("environment"), dict) else None
    path_costs = {}
    for sample in samples:
        costs = sample.get("path_costs")
        if not isinstance(costs, dict):
            continue
        for name, cost in costs.items():
            if not isinstance(cost, dict):
                continue
            entry = path_costs.setdefault(str(name)[:96], {"calls": 0, "total_ms": 0, "max_ms": 0})
            entry["calls"] += number(cost.get("calls"))
            entry["total_ms"] += number(cost.get("total_ms"))
            entry["max_ms"] = max(entry["max_ms"], number(cost.get("max_ms")))
    return {
        "capture_id": report.get("capture_id"),
        "environment": report.get("environment", {}),
        "diagnostics_revision": report.get("diagnostics_revision", 1),
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
        "completed_main_queue_delays_over_250ms": sum(entry["event"] == "main_queue.recovered" for entry in stalls),
        "peak_main_cpu_percent": peak_cpu(samples, "main_cpu_percent"),
        "peak_process_cpu_percent": peak_cpu(samples, "process_cpu_percent"),
        "initial_screen_captured": initial_capture if isinstance(initial_capture, bool) else None,
        "screen_capture_changes": capture_changes,
        "thread_probe_disabled": disabled,
        "thread_samples": thread_samples,
        "sampled_code_locations": [dict(reason=key[0], depth=key[1], image=key[2], uuid=key[3],
                                        image_offset=key[4], symbol=key[5], symbol_offset=key[6], count=count)
                                   for key, count in locations.most_common(40)],
        "path_cost_totals": path_costs,
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
