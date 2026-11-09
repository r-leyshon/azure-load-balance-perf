#!/usr/bin/env python3
"""Confirm from Azure Monitor that a pinned-gateway run (rlC_*) only reached its pinned region.

Writes experiment/results/<run_id>.azmon.json: {"ok": bool, "reason": str, "calls": {...}}.
Needs the run isolated by >=3 minutes idle either side (the driver ensures this).
Usage: RUN_SECONDS=640 python3 -I scripts/region_pin_check.py RUN_ID PINNED_REGION
"""
import importlib.util, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("frc", os.path.join(HERE, "foundry_region_counts.py"))
frc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(frc)

run_id, pinned = sys.argv[1], sys.argv[2]
counts = frc.counts(run_id)
calls = {r: sum(v.values()) for r, v in counts.items()}
res = json.load(open(os.path.join(frc.RES, run_id + ".json")))["metrics"]
sent = sum(int(res.get(f"requests_{r}", {}).get("values", {}).get("count", 0)) for r in calls)

others = {r: c for r, c in calls.items() if r != pinned and c > 0}
if others:
    ok, reason = False, f"traffic reached unpinned regions: {others}"
elif calls.get(pinned, 0) < 0.98 * sent:
    ok, reason = False, f"only {calls.get(pinned, 0)} Foundry calls for {sent} requests sent"
else:
    ok, reason = True, ""
out = {"ok": ok, "reason": reason, "pinned": pinned, "requests_sent": sent, "foundry_calls": calls}
json.dump(out, open(os.path.join(frc.RES, run_id + ".azmon.json"), "w"), indent=1)
print(("PIN OK " if ok else "PIN FAILED ") + json.dumps(out))
sys.exit(0 if ok else 1)
