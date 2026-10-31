import http from "k6/http";
import { check, sleep } from "k6";

// All configuration comes from environment variables — no values hardcoded.
const DEPLOYMENT_ID = __ENV.DEPLOYMENT_ID || "chat";
const RUN_ID        = __ENV.RUN_ID   || "unnamed";
const VUS           = parseInt(__ENV.VUS  || "20");
const ITER          = parseInt(__ENV.ITER || "200");
// "sequential" — try UK South, West Europe, Sweden Central in order on 429/5xx.
// "weighted"   — probabilistic selection by weight (60/25/15), no fallback.
const MODE          = __ENV.DIRECT_MODE || "sequential";

const ENDPOINTS = [
  { url: __ENV.FOUNDRY_ENDPOINT_UKSOUTH,       key: __ENV.FOUNDRY_KEY_UKSOUTH,       region: "uksouth",       weight: 60 },
  { url: __ENV.FOUNDRY_ENDPOINT_WESTEUROPE,    key: __ENV.FOUNDRY_KEY_WESTEUROPE,    region: "westeurope",    weight: 25 },
  { url: __ENV.FOUNDRY_ENDPOINT_SWEDENCENTRAL, key: __ENV.FOUNDRY_KEY_SWEDENCENTRAL, region: "swedencentral", weight: 15 },
];

for (const ep of ENDPOINTS) {
  if (!ep.url || !ep.key) throw new Error(`Missing env vars for region ${ep.region}`);
}

export const options = {
  vus:        VUS,
  iterations: ITER,
  summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"],
};

const PAYLOAD = JSON.stringify({
  messages: [{ role: "user", content: "Reply with exactly one word: Hello." }],
  max_tokens: 5,
});

function buildUrl(ep) {
  return `${ep.url}openai/deployments/${DEPLOYMENT_ID}/chat/completions?api-version=2024-02-01`;
}

function buildHeaders(ep) {
  return {
    "Content-Type": "application/json",
    "api-key":      ep.key,
    "X-Run-Id":     RUN_ID,
  };
}

// Pick one endpoint by weight — used in weighted mode.
function weightedPick() {
  const totalWeight = ENDPOINTS.reduce((s, e) => s + e.weight, 0);
  let r = Math.random() * totalWeight;
  for (const ep of ENDPOINTS) {
    r -= ep.weight;
    if (r <= 0) return ep;
  }
  return ENDPOINTS[ENDPOINTS.length - 1];
}

export default function () {
  let res;

  if (MODE === "sequential") {
    // Try each region in order; stop on first 200.
    for (const ep of ENDPOINTS) {
      res = http.post(buildUrl(ep), PAYLOAD, { headers: buildHeaders(ep) });
      if (res.status === 200) break;
    }
  } else {
    // Weighted random — one shot, no fallback.
    const ep = weightedPick();
    res = http.post(buildUrl(ep), PAYLOAD, { headers: buildHeaders(ep) });
  }

  check(res, {
    "http 200 ok":        (r) => r.status === 200,
    "http 429 throttled": (r) => r.status === 429,
    "no server error":    (r) => r.status < 500,
  });

  sleep(0.1);
}

export function handleSummary(data) {
  const path = `experiment/results/${RUN_ID}.json`;
  console.log(`Summary written to ${path}`);
  return { [path]: JSON.stringify(data, null, 2) };
}
