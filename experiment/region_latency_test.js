import http from "k6/http";
import exec from "k6/execution";
import { Counter, Trend } from "k6/metrics";

// Per-region latency measurement. One attempt per request: no retries, no failover, no memory.
// All configuration comes from environment variables — no values hardcoded.
//
// MODE=interleaved  direct to Foundry, round-robin across the three regions (RATE_PER_S is the TOTAL rate)
// MODE=single       direct to Foundry, one region (REGION)
// MODE=apim         via the APIM gateway; REGION labels the region the gateway is pinned to
const DEPLOYMENT_ID     = __ENV.DEPLOYMENT_ID || "chat";
const RUN_ID            = __ENV.RUN_ID        || "unnamed";
const MODE              = __ENV.MODE          || "interleaved";
const REGION            = __ENV.REGION        || "";
const RATE_PER_S        = parseFloat(__ENV.RATE_PER_S || "1.5");
const DURATION_S        = parseInt(__ENV.DURATION_S   || "640");
const WARMUP_PER_REGION = parseInt(__ENV.WARMUP_PER_REGION || "20");

const REGIONS = ["uksouth", "westeurope", "swedencentral"];
const FOUNDRY = {
  uksouth:       { url: __ENV.FOUNDRY_ENDPOINT_UKSOUTH,       key: __ENV.FOUNDRY_KEY_UKSOUTH },
  westeurope:    { url: __ENV.FOUNDRY_ENDPOINT_WESTEUROPE,    key: __ENV.FOUNDRY_KEY_WESTEUROPE },
  swedencentral: { url: __ENV.FOUNDRY_ENDPOINT_SWEDENCENTRAL, key: __ENV.FOUNDRY_KEY_SWEDENCENTRAL },
};
const APIM_URL = __ENV.APIM_GATEWAY_URL;
const APIM_KEY = __ENV.APIM_SUBSCRIPTION_KEY;

if (!["interleaved", "single", "apim"].includes(MODE)) throw new Error(`bad MODE ${MODE}`);
if (MODE !== "interleaved" && !REGIONS.includes(REGION)) throw new Error("REGION must be set for single/apim");
if (MODE === "apim") {
  if (!APIM_URL || !APIM_KEY) throw new Error("APIM_GATEWAY_URL and APIM_SUBSCRIPTION_KEY are required");
} else {
  for (const r of (MODE === "single" ? [REGION] : REGIONS)) {
    if (!FOUNDRY[r].url || !FOUNDRY[r].key) throw new Error(`Missing Foundry env vars for ${r}`);
  }
}

// k6 arrival rate is an integer per timeUnit; express fractional req/s over a 10 s unit.
export const options = {
  scenarios: {
    constant_load: {
      executor: "constant-arrival-rate",
      rate: Math.round(RATE_PER_S * 10),
      timeUnit: "10s",
      duration: `${DURATION_S}s`,
      // ~1 request in flight at these rates; few VUs keeps cold connections inside the warm-up window.
      preAllocatedVUs: 2,
      maxVUs: 30,
    },
  },
  summaryTrendStats: ["count", "avg", "p(50)", "p(95)", "p(99)", "max"],
};

// Per-region metrics. latency_* = http_req_duration of valid 200s after warm-up.
const latency   = {};  // all measured samples
const reused    = {};  // measured samples on an already-open connection
const warmup    = {};  // first WARMUP_PER_REGION requests per region (reported, never mixed)
const sent      = {};
const nonOk     = {};  // any non-200 or invalid body, warm-up included
const s429      = {};
const s5xx      = {};
const newConn   = {};  // measured samples that opened a new TCP/TLS connection
for (const r of REGIONS) {
  latency[r] = new Trend(`latency_${r}`, true);
  reused[r]  = new Trend(`latency_reused_${r}`, true);
  warmup[r]  = new Trend(`latency_warmup_${r}`, true);
  sent[r]    = new Counter(`requests_${r}`);
  nonOk[r]   = new Counter(`non200_${r}`);
  s429[r]    = new Counter(`status429_${r}`);
  s5xx[r]    = new Counter(`status5xx_${r}`);
  newConn[r] = new Counter(`newconn_${r}`);
}

const PAYLOAD = JSON.stringify({
  messages: [{ role: "user", content: "Reply with exactly one word: Hello." }],
  max_tokens: 5,
});

function target(region) {
  if (MODE === "apim") {
    return {
      url: `${APIM_URL.replace(/\/$/, "")}/openai/deployments/${DEPLOYMENT_ID}/chat/completions?api-version=2024-02-01`,
      headers: { "Content-Type": "application/json", "Ocp-Apim-Subscription-Key": APIM_KEY, "X-Run-Id": RUN_ID },
    };
  }
  const ep = FOUNDRY[region];
  return {
    url: `${ep.url}openai/deployments/${DEPLOYMENT_ID}/chat/completions?api-version=2024-02-01`,
    headers: { "Content-Type": "application/json", "api-key": ep.key, "X-Run-Id": RUN_ID },
  };
}

export default function () {
  const i = exec.scenario.iterationInTest;  // unique, increasing across all VUs
  let region, n;                            // n = per-region sequence number
  if (MODE === "interleaved") { region = REGIONS[i % 3]; n = Math.floor(i / 3); }
  else                        { region = REGION;          n = i; }
  const isWarmup = n < WARMUP_PER_REGION;

  const t = target(region);
  const res = http.post(t.url, PAYLOAD, {
    headers: t.headers,
    tags: { region, phase: isWarmup ? "warmup" : "measured", mode: MODE },
  });
  sent[region].add(1);

  let valid = false;
  if (res.status === 200) {
    try {
      const body = JSON.parse(res.body);
      valid = Array.isArray(body.choices) && body.choices.length > 0;
    } catch { /* non-JSON 200 */ }
  }
  if (res.status === 429) s429[region].add(1);
  if (res.status >= 500) s5xx[region].add(1);
  if (!valid) { nonOk[region].add(1); return; }

  const ms = res.timings.duration;
  if (isWarmup) { warmup[region].add(ms); return; }
  latency[region].add(ms);
  if (res.timings.connecting > 0) newConn[region].add(1); else reused[region].add(ms);
}

export function handleSummary(data) {
  const path = `experiment/results/${RUN_ID}.json`;
  data.run_meta = {
    mode: MODE, region: REGION || "all", rate_per_s_total: RATE_PER_S, duration_s: DURATION_S,
    warmup_per_region: WARMUP_PER_REGION, connection_reuse: true,
  };
  console.log(`Summary written to ${path}`);
  return { [path]: JSON.stringify(data, null, 2) };
}
