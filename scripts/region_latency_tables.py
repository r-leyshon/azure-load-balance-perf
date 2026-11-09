#!/usr/bin/env python3
"""Tables and validity checks for the per-region latency experiment (runs rlA_*, rlB_*, rlC_*).

Run ids:  rlA_r<N>               condition A  direct, interleaved across the three regions
          rlB_<region>_r<N>      condition B  direct, one region per run
          rlC_<region>_r<N>      condition C  via APIM pinned to <region>
A suffix _x<N> marks a re-run of a discarded run (same logical id).

Usage:
  python3 -I scripts/region_latency_tables.py --check RUN_ID   # exit 1 if the run is invalid
  python3 -I scripts/region_latency_tables.py                  # all tables
"""
import glob, json, os, re, statistics, sys
from collections import defaultdict
from datetime import datetime, timezone

RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "experiment", "results")
REGIONS = ["uksouth", "westeurope", "swedencentral"]
MIN_MEASURED = 295          # planned ~300 measured samples per region after warm-up
WALL_SLACK_S = 30           # run is invalid if wall time exceeds planned duration by more than this
ID_RE = re.compile(r"^rl([ABC])(?:_([a-z]+))?_r(\d+)(?:_x(\d+))?$")


def load(run_id):
    d = json.load(open(os.path.join(RES, run_id + ".json")))
    m = d["metrics"]
    cnt = lambda k: int(m.get(k, {}).get("values", {}).get("count", 0))
    meta = d.get("run_meta", {})
    reg = {}
    for r in REGIONS:
        t = m.get(f"latency_{r}", {}).get("values", {})
        reg[r] = dict(
            n=int(t.get("count", 0)), med=t.get("p(50)"), p95=t.get("p(95)"), p99=t.get("p(99)"), mx=t.get("max"),
            sent=cnt(f"requests_{r}"), non200=cnt(f"non200_{r}"), s429=cnt(f"status429_{r}"),
            s5xx=cnt(f"status5xx_{r}"), newconn=cnt(f"newconn_{r}"),
            reused_med=m.get(f"latency_reused_{r}", {}).get("values", {}).get("p(50)"),
            warm_med=m.get(f"latency_warmup_{r}", {}).get("values", {}).get("p(50)"),
        )
    wall = d.get("state", {}).get("testRunDurationMs", 0) / 1000
    mt = None
    mp = os.path.join(RES, run_id + ".meta.json")
    if os.path.exists(mp):
        mt = json.load(open(mp))
    utc = (mt or {}).get("utc_start")
    if not utc:
        end = os.path.getmtime(os.path.join(RES, run_id + ".json"))
        utc = datetime.fromtimestamp(end - wall, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    az = None
    ap = os.path.join(RES, run_id + ".azmon.json")
    if os.path.exists(ap):
        az = json.load(open(ap))
    return dict(id=run_id, meta=meta, reg=reg, wall=wall, utc=utc, az=az,
                dropped=cnt("dropped_iterations"), planned=int(meta.get("duration_s", 0)))


def validity(run, cond, region):
    """Return a list of reasons the run is invalid (empty list = valid)."""
    why = []
    active = [r for r in REGIONS if run["reg"][r]["sent"] > 0]
    if run["planned"] and run["wall"] > run["planned"] + WALL_SLACK_S:
        why.append(f"wall {run['wall']:.0f}s > planned {run['planned']}s+{WALL_SLACK_S}")
    if run["dropped"] > 0:
        why.append(f"{run['dropped']} dropped iterations")
    for r in active:
        x = run["reg"][r]
        if x["non200"] or x["s429"] or x["s5xx"]:
            why.append(f"{r}: {x['non200']} non-200 ({x['s429']}x429, {x['s5xx']}x5xx)")
        if x["n"] < MIN_MEASURED:
            why.append(f"{r}: only {x['n']} measured samples")
    if cond == "C":
        if run["az"] is None:
            why.append("no Azure Monitor config check yet")
        elif not run["az"].get("ok"):
            why.append("Azure Monitor: " + run["az"].get("reason", "pinning not confirmed"))
    return why


def parse(run_id):
    m = ID_RE.match(run_id)
    if not m:
        return None
    cond, region, rep, rerun = m.groups()
    return cond, (region or "all"), int(rep), int(rerun or 1)


def collect():
    runs = []
    for p in sorted(glob.glob(os.path.join(RES, "rl[ABC]_*.json"))):
        rid = os.path.basename(p)[:-5]
        if rid.endswith((".meta", ".azmon")) or ".meta" in rid or ".azmon" in rid or ".config" in rid:
            continue
        pr = parse(rid)
        if not pr:
            continue
        cond, region, rep, rerun = pr
        run = load(rid)
        run.update(cond=cond, region=region, rep=rep, rerun=rerun, why=validity(run, cond, region))
        run["valid"] = not run["why"]
        runs.append(run)
    return runs


def ms(v):
    return "-" if v is None else f"{v:.0f}"


def rng(vals):
    return "-" if not vals else (f"{statistics.median(vals):.0f} [{min(vals):.0f}-{max(vals):.0f}]")


def main():
    runs = collect()
    print("### Runs\n")
    print("| run | cond | UTC start | region | n | median | p95 | p99 | max | non-200 | dropped | wall s | valid |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|---|")
    for r in runs:
        for reg in REGIONS:
            x = r["reg"][reg]
            if x["sent"] == 0:
                continue
            ok = "yes" if r["valid"] else "NO: " + "; ".join(r["why"])
            print(f"| `{r['id']}` | {r['cond']} | {r['utc']} | {reg} | {x['n']} | {ms(x['med'])} | {ms(x['p95'])} | "
                  f"{ms(x['p99'])} | {ms(x['mx'])} | {x['non200']} | {r['dropped']} | {r['wall']:.0f} | {ok} |")

    valid = [r for r in runs if r["valid"]]
    agg = defaultdict(lambda: defaultdict(list))   # (cond, region) -> stat -> list over valid runs
    for r in valid:
        regs = REGIONS if r["cond"] == "A" else [r["region"]]
        for reg in regs:
            x = r["reg"][reg]
            for k in ("med", "p95", "p99"):
                agg[(r["cond"], reg)][k].append(x[k])
            agg[(r["cond"], reg)]["newshare"].append(x["newconn"] / x["n"] if x["n"] else 0)
            agg[(r["cond"], reg)]["reused_med"].append(x["reused_med"])
            agg[(r["cond"], reg)]["warm_med"].append(x["warm_med"])

    print("\n### Per condition and region (valid runs only): median over runs [min-max across runs], ms\n")
    print("| cond | region | valid runs | median | p95 | p99 | new-connection share of samples | warm-up median |")
    print("|---|---|---|---|---|---|---|---|")
    for cond in "ABC":
        for reg in REGIONS:
            a = agg.get((cond, reg))
            if not a:
                continue
            share = statistics.mean(a["newshare"]) * 100
            wm = [v for v in a["warm_med"] if v is not None]
            print(f"| {cond} | {reg} | {len(a['med'])} | {rng(a['med'])} | {rng(a['p95'])} | {rng(a['p99'])} | "
                  f"{share:.1f}% | {ms(statistics.median(wm)) if wm else '-'} |")

    print("\n### Gateway overhead per region (C minus direct), ms; difference of run-medians\n")
    print("| region | vs | median | p95 | p99 | run-to-run range of medians (C / direct) |")
    print("|---|---|---|---|---|---|")
    for reg in REGIONS:
        c = agg.get(("C", reg))
        for dc, label in (("A", "A (interleaved)"), ("B", "B (single)")):
            d = agg.get((dc, reg))
            if not c or not d:
                continue
            diff = lambda k: statistics.median(c[k]) - statistics.median(d[k])
            cr = max(c["med"]) - min(c["med"]); dr = max(d["med"]) - min(d["med"])
            print(f"| {reg} | {label} | {diff('med'):+.0f} | {diff('p95'):+.0f} | {diff('p99'):+.0f} | {cr:.0f} / {dr:.0f} |")

    print("\n### Condition A: ordering and pairwise differences per repeat (median ms)\n")
    arun = [r for r in valid if r["cond"] == "A"]
    for r in sorted(arun, key=lambda r: r["utc"]):
        order = sorted(REGIONS, key=lambda g: r["reg"][g]["med"])
        print(f"- `{r['id']}` {r['utc']}: " + " < ".join(f"{g} {r['reg'][g]['med']:.0f}" for g in order))
    if len(arun) >= 2:
        print("\nPre-registered rule (A): region Y is slower than X if its median is >20 ms higher in EVERY valid repeat.")
        for i, x in enumerate(REGIONS):
            for y in REGIONS[i + 1:]:
                d = [r["reg"][y]["med"] - r["reg"][x]["med"] for r in arun]
                if all(v > 20 for v in d):
                    verdict = f"{y} slower than {x}"
                elif all(v < -20 for v in d):
                    verdict = f"{x} slower than {y}"
                else:
                    verdict = "no consistent >20 ms difference"
                print(f"- {x} vs {y}: differences (y-x) = {[round(v) for v in d]} -> {verdict}")

    bad = [r for r in runs if not r["valid"]]
    print("\n### Discarded runs\n")
    for r in bad:
        print(f"- `{r['id']}`: " + "; ".join(r["why"]))
    if not bad:
        print("- none")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--check":
        rid = sys.argv[2]
        cond, region, _, _ = parse(rid)
        run = load(rid)
        why = validity(run, cond, region)
        # a C run is checked against Azure Monitor separately, after the metric lag
        if cond == "C":
            why = [w for w in why if "Azure Monitor" not in w]
        print("VALID" if not why else "INVALID: " + "; ".join(why))
        sys.exit(0 if not why else 1)
    main()
