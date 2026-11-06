#!/usr/bin/env python3
"""Per-region Foundry request counts (by status) for a k6 run, from Azure Monitor.

Azure Monitor 1-minute buckets lag request time by up to ~1 minute, so a tight window loses
tail traffic. Window = [mtime-300s-120s, mtime+180s] of experiment/results/<run_id>.json, which is
only valid when the run was isolated by >=3 minutes idle on both sides (p5r_* runs).
Usage: python3 -I scripts/foundry_region_counts.py RUN_ID [RUN_ID ...]
"""
import json, os, subprocess, sys
from datetime import datetime, timedelta, timezone

RG = "rg-apim-foundry-perf"
RES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "experiment", "results")

def _sub():
    tfvars = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "infra", "terraform.tfvars")
    for line in open(tfvars):
        if line.strip().startswith("subscription_id"):
            return line.split("=", 1)[1].strip().strip('"')
    raise SystemExit("subscription_id not found in infra/terraform.tfvars")

SUB = _sub()  # project subscription, not the CLI default

def az(*args):
    out = subprocess.run(["az", *args, "--subscription", SUB], capture_output=True, text=True, check=True).stdout
    return json.loads(out)

ACCOUNTS = {a["name"].split("-")[1]: a["id"]
            for a in az("cognitiveservices", "account", "list", "-g", RG, "--query", "[].{name:name,id:id}", "-o", "json")}

def counts(run_id):
    end = datetime.fromtimestamp(os.path.getmtime(os.path.join(RES, run_id + ".json")), timezone.utc)
    start = (end - timedelta(seconds=420)).replace(second=0, microsecond=0)
    res = {}
    for region, rid in ACCOUNTS.items():
        d = az("monitor", "metrics", "list", "--resource", rid, "--metric", "ModelRequests",
               "--interval", "PT1M", "--aggregation", "Total", "--filter", "StatusCode eq '*'",
               "--start-time", start.strftime("%Y-%m-%dT%H:%M:%SZ"),
               "--end-time", (end + timedelta(seconds=180)).strftime("%Y-%m-%dT%H:%M:%SZ"), "-o", "json")
        by = {}
        for ts in d["value"][0]["timeseries"]:
            code = next((m["value"] for m in ts.get("metadatavalues", []) if m["name"]["value"] == "statuscode"), "?")
            by[code] = by.get(code, 0) + int(sum(p.get("total") or 0 for p in ts["data"]))
        res[region] = by
    return res

if __name__ == "__main__":
    for rid in sys.argv[1:]:
        print(json.dumps({"run_id": rid, "foundry": counts(rid)}))
