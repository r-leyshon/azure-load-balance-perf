import http from "k6/http";
import { check } from "k6";
import { Counter, Trend } from "k6/metrics";

// All configuration comes from environment variables — no values hardcoded.
const DEPLOYMENT_ID  = __ENV.DEPLOYMENT_ID  || "chat";
const RUN_ID         = __ENV.RUN_ID         || "unnamed";
const RATE_PER_S     = parseInt(__ENV.RATE_PER_S    || "2");
const DURATION       = __ENV.DURATION               || "5m";
const PRE_ALLOC_VUS  = parseInt(__ENV.PRE_ALLOC_VUS || "30");
const MAX_VUS        = parseInt(__ENV.MAX_VUS        || "60");
const MAX_RETRIES    = parseInt(__ENV.MAX_RETRIES    || "3");

// RETRY_MODE controls endpoint re-selection behaviour:
//   "weighted" — re-enter the full weighted pool on every retry attempt (UK South still
//                gets 90% of retries). Matches APIM retry without CB: retries are unguided.
//   "memory"   — after a 429, exclude that region for MEMORY_SECONDS per-VU. Retries are
//                forced to regions without recent failures. Approximates APIM CB on 429,
//                but the memory is VU-local (not shared across VUs as APIM's CB is).
const RETRY_MODE     = __ENV.RETRY_MODE     || "weighted";
const MEMORY_SECONDS = parseInt(__ENV.MEMORY_SECONDS || "60");

const ENDPOINTS = [
  {
    url:    __ENV.FOUNDRY_ENDPOINT_UKSOUTH,
    key:    __ENV.FOUNDRY_KEY_UKSOUTH,
    region: "uksouth",
    weight: parseInt(__ENV.WEIGHT_UKSOUTH       || "90"),
  },
  {
    url:    __ENV.FOUNDRY_ENDPOINT_WESTEUROPE,
    key:    __ENV.FOUNDRY_KEY_WESTEUROPE,
    region: "westeurope",
    weight: parseInt(__ENV.WEIGHT_WESTEUROPE    || "5"),
  },
  {
    url:    __ENV.FOUNDRY_ENDPOINT_SWEDENCENTRAL,
    key:    __ENV.FOUNDRY_KEY_SWEDENCENTRAL,
    region: "swedencentral",
    weight: parseInt(__ENV.WEIGHT_SWEDENCENTRAL || "5"),
  },
];

for (const ep of ENDPOINTS) {
  if (!ep.url || !ep.key) throw new Error(`Missing env vars for region ${ep.region}`);
}

export const options = {
  scenarios: {
    constant_load: {
      executor: "constant-arrival-rate",
      rate: RATE_PER_S,
      timeUnit: "1s",
      duration: DURATION,
      preAllocatedVUs: PRE_ALLOC_VUS,
      maxVUs: MAX_VUS,
    },
  },
  summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"],
};

const originalIterations = new Counter("original_iterations");
const eventualSuccesses  = new Counter("eventual_successes");
const totalHttpCalls     = new Counter("total_http_calls");
const callsUksouth       = new Counter("calls_uksouth");
const callsWesteurope    = new Counter("calls_westeurope");
const callsSwedencentral = new Counter("calls_swedencentral");
const timeToSuccess      = new Trend("time_to_success", true);

const PAYLOAD = JSON.stringify({
  messages: [{ role: "user", content: "Reply with exactly one word: Hello." }],
  max_tokens: 5,
});

function buildUrl(ep) {
  return `${ep.url}openai/deployments/${DEPLOYMENT_ID}/chat/completions?api-version=2024-02-01`;
}

function buildHeaders(ep) {
  return { "Content-Type": "application/json", "api-key": ep.key, "X-Run-Id": RUN_ID };
}

// VU-local per-region last-429 timestamp. Used only in "memory" mode.
const last429 = {};

function isBlocked(region) {
  const t = last429[region];
  return t !== undefined && (Date.now() - t) < MEMORY_SECONDS * 1000;
}

// Select an endpoint by weighted random sampling.
//
// "weighted" mode: sample from the full pool including already-tried regions.
//   The same region can be selected multiple times across attempts — this matches
//   how APIM re-enters the weighted pool on each retry when no CB is configured.
//
// "memory" mode: exclude regions that returned 429 within MEMORY_SECONDS (per this VU)
//   and exclude regions already tried this iteration. If all untried regions are in
//   cooldown, fall back to picking from untried-only (ignore cooldown).
function selectEndpoint(tried) {
  let candidates;

  if (RETRY_MODE === "weighted") {
    candidates = ENDPOINTS;
  } else {
    candidates = ENDPOINTS.filter(ep => !tried.includes(ep.region) && !isBlocked(ep.region));
    if (candidates.length === 0) {
      candidates = ENDPOINTS.filter(ep => !tried.includes(ep.region));
    }
  }

  if (candidates.length === 0) return null;

  const totalWeight = candidates.reduce((sum, ep) => sum + ep.weight, 0);
  let rand = Math.random() * totalWeight;
  for (const ep of candidates) {
    rand -= ep.weight;
    if (rand <= 0) return ep;
  }
  return candidates[candidates.length - 1];
}

const regionCounters = {
  uksouth:       callsUksouth,
  westeurope:    callsWesteurope,
  swedencentral: callsSwedencentral,
};

export default function () {
  originalIterations.add(1);
  const startMs = Date.now();
  let finalRes = null;
  let bodyValid = false;
  const tried = [];

  for (let attempt = 0; attempt < MAX_RETRIES; attempt++) {
    const ep = selectEndpoint(tried);
    if (!ep) break;

    tried.push(ep.region);
    const res = http.post(buildUrl(ep), PAYLOAD, { headers: buildHeaders(ep) });
    totalHttpCalls.add(1);
    regionCounters[ep.region].add(1);
    finalRes = res;

    if (res.status === 429 && RETRY_MODE === "memory") {
      last429[ep.region] = Date.now();
    }

    if (res.status === 200) {
      try {
        const body = JSON.parse(res.body);
        bodyValid = Array.isArray(body.choices) && body.choices.length > 0;
      } catch { /* non-JSON 200 */ }
      if (bodyValid) break;
    }
  }

  if (bodyValid) {
    eventualSuccesses.add(1);
    timeToSuccess.add(Date.now() - startMs);
  }

  if (finalRes) {
    check(finalRes, {
      "http 200 ok":        (r) => r.status === 200,
      "body has choices":   () => finalRes.status !== 200 || bodyValid,
      "http 429 throttled": (r) => r.status === 429,
      "no server error":    (r) => r.status < 500,
    });
  }
}

export function handleSummary(data) {
  const path = `experiment/results/${RUN_ID}.json`;
  console.log(`Summary written to ${path}`);
  return { [path]: JSON.stringify(data, null, 2) };
}
