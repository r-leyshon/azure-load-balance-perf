"""
Parse k6 JSON summary files and print a Markdown comparison table.

Usage:
    python experiment/summarise.py --results experiment/results/
"""

import argparse
import json
import os
import sys


def load_result(path: str) -> dict:
    with open(path) as f:
        return json.load(f)


def extract_metrics(data: dict, run_id: str) -> dict:
    metrics = data.get("metrics", {})

    def trend(key: str, stat: str) -> float:
        return round(metrics.get(key, {}).get("values", {}).get(stat, 0), 1)

    def counter(key: str) -> int:
        return int(metrics.get(key, {}).get("values", {}).get("count", 0))

    total_reqs = counter("http_reqs")
    fail_rate  = metrics.get("http_req_failed", {}).get("values", {}).get("rate", 1.0)

    # Prefer the explicit eventual_successes counter (retry-aware runs).
    # Fall back to http_req_failed-derived count for Phase 1 runs.
    eventual_count = counter("eventual_successes")
    # original_iterations is a custom counter written once per VU iteration.
    # Falls back to total HTTP requests for Phase 1 runs that predate the counter.
    orig_iters = counter("original_iterations") or total_reqs

    if eventual_count > 0:
        http_200       = eventual_count
        total_http     = counter("total_http_calls") or total_reqs
        retry_overhead = round((total_http / max(orig_iters, 1) - 1), 2)
    else:
        http_200       = int(round(total_reqs * (1 - fail_rate)))
        total_http     = total_reqs
        retry_overhead = None

    http_200_pct = round(http_200 / max(orig_iters, 1) * 100, 1)

    row = {
        "run_id":        run_id,
        "iterations":    orig_iters,
        "http_200":      http_200,
        "http_200_%":    http_200_pct,
        "total_calls":   total_http,
        "avg_ms":        trend("http_req_duration", "avg"),
        "p50_ms":        trend("http_req_duration", "p(50)"),
        "p95_ms":        trend("http_req_duration", "p(95)"),
        "tts_p50_ms":    trend("time_to_success", "p(50)") or "-",
        "tts_p95_ms":    trend("time_to_success", "p(95)") or "-",
        "retry_overhead": retry_overhead if retry_overhead is not None else "-",
    }
    return row


def print_table(rows: list[dict]) -> None:
    headers = [
        "run_id", "iterations", "http_200", "http_200_%",
        "total_calls", "avg_ms", "p50_ms", "p95_ms",
        "tts_p50_ms", "tts_p95_ms", "retry_overhead",
    ]
    widths = [max(len(h), max(len(str(r[h])) for r in rows)) for h in headers]

    def fmt_row(values):
        return "| " + " | ".join(str(v).ljust(w) for v, w in zip(values, widths)) + " |"

    print(fmt_row(headers))
    print("|" + "|".join("-" * (w + 2) for w in widths) + "|")
    for row in rows:
        print(fmt_row([row[h] for h in headers]))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", default="experiment/results/", help="Directory of k6 JSON files")
    args = parser.parse_args()

    if not os.path.isdir(args.results):
        sys.exit(f"Results directory not found: {args.results}")

    rows = []
    for fname in sorted(os.listdir(args.results)):
        if not fname.endswith(".json"):
            continue
        run_id = fname.removesuffix(".json")
        path   = os.path.join(args.results, fname)
        try:
            rows.append(extract_metrics(load_result(path), run_id))
        except Exception as exc:
            print(f"Warning: could not parse {fname}: {exc}", file=sys.stderr)

    if not rows:
        sys.exit("No result files found.")

    print_table(rows)


if __name__ == "__main__":
    main()
