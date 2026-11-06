#!/usr/bin/env python3
"""Markdown tables for Phase 5/6 runs, applying the validity rule.

A run is INVALID if its k6 duration exceeds 330 s (5-minute runs; a longer duration means the
machine slept mid-run) or it has dropped iterations. Invalid runs are listed, not averaged.
Usage: python3 -I scripts/phase5_tables.py PREFIX [PREFIX ...]   e.g. p6a p6b p6d
"""
import glob, json, os, statistics, sys
from collections import defaultdict

RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "experiment", "results")


def load(path):
    d = json.load(open(path))
    m = d["metrics"]
    v = lambda k, s="count": m.get(k, {}).get("values", {}).get(s, 0)
    t = m.get("time_to_success", {}).get("values", {})
    orig, succ = v("original_iterations"), v("eventual_successes")
    return dict(
        succ=round(succ / orig * 100, 1) if orig else 0.0,
        p50=round(t.get("p(50)", 0)), p95=round(t.get("p(95)", 0)),
        calls=v("total_http_calls") / orig if orig else 0,
        dur=d.get("state", {}).get("testRunDurationMs", 0) / 1000,
        drop=int(v("dropped_iterations")),
    )


def main(prefixes):
    arms = defaultdict(lambda: {"ok": [], "bad": []})
    for pre in prefixes:
        for p in sorted(glob.glob(os.path.join(RES, f"{pre}_*.json"))):
            if "config" in p or "region_counts" in p:
                continue
            rid = os.path.basename(p)[:-5]
            arm = rid.rsplit("_r", 1)[0]
            r = load(p)
            (arms[arm]["bad"] if (r["dur"] > 330 or r["drop"] > 0) else arms[arm]["ok"]).append((rid, r))
    print("| arm | valid n | success % (valid runs) | median | tts p50 ms | tts p95 ms | invalid (excluded) |")
    print("|---|---|---|---|---|---|---|")
    for arm, g in sorted(arms.items()):
        ok = [r for _, r in g["ok"]]
        bad = ", ".join(f"{rid.rsplit('_r', 1)[1]}" for rid, _ in g["bad"]) or "-"
        if ok:
            print(f"| `{arm}` | {len(ok)} | {' / '.join(str(r['succ']) for r in ok)} | "
                  f"**{statistics.median(r['succ'] for r in ok)}** | "
                  f"{statistics.median(r['p50'] for r in ok):.0f} | {statistics.median(r['p95'] for r in ok):.0f} | r{bad} |")
        else:
            print(f"| `{arm}` | 0 | - | - | - | - | r{bad} |")


if __name__ == "__main__":
    main(sys.argv[1:] or ["p6a"])
