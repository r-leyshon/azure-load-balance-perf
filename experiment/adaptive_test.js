import http from "k6/http";
import { check } from "k6";
import { Counter, Trend } from "k6/metrics";

// ---------------------------------------------------------------------------
// Configuration — all values from environment variables, nothing hardcoded.
// ---------------------------------------------------------------------------
const DEPLOYMENT_ID      = __ENV.DEPLOYMENT_ID || "chat";
const RUN_ID             = __ENV.RUN_ID        || "unnamed";
const VUS                = parseInt(__ENV.VUS   || "20");
const ITER               = parseInt(__ENV.ITER  || "200");
const DURATION           = __ENV.DURATION      || null;

// Adaptive weight parameters
const ADAPT_INTERVAL_MS  = parseInt(__ENV.ADAPT_INTERVAL_S || "30") * 1000;
const ERROR_PENALTY      = parseFloat(__ENV.ERROR_PENALTY  || "5");
// Minimum weight fraction per region — prevents full abandonment.
const EPSILON            = parseFloat(__ENV.EPSILON        || "0.05");

const ENDPOINTS = [
  { url: __ENV.FOUNDRY_ENDPOINT_UKSOUTH,       key: __ENV.FOUNDRY_KEY_UKSOUTH,       region: "uksouth" },
  { url: __ENV.FOUNDRY_ENDPOINT_WESTEUROPE,    key: __ENV.FOUNDRY_KEY_WESTEUROPE,    region: "westeurope" },
  { url: __ENV.FOUNDRY_ENDPOINT_SWEDENCENTRAL, key: __ENV.FOUNDRY_KEY_SWEDENCENTRAL, region: "swedencentral" },
];

for (const ep of ENDPOINTS) {
  if (!ep.url || !ep.key) throw new Error(`Missing env vars for region ${ep.region}`);
}

// ---------------------------------------------------------------------------
// Custom metrics — same surface as load_test.js for summarise.py compatibility.
// ---------------------------------------------------------------------------
const eventualSuccesses  = new Counter("eventual_successes");
const originalIterations = new Counter("original_iterations");
const timeToSuccess      = new Trend("time_to_success", true);

export const options = DURATION
  ? { vus: VUS, duration: DURATION, summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"] }
  : { vus: VUS, iterations: ITER,   summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"] };

const PAYLOAD = JSON.stringify({
  messages: [{ role: "user", content: "Reply with exactly one word: Hello." }],
  max_tokens: 5,
});

// ---------------------------------------------------------------------------
// Per-VU state. k6 VUs each get an isolated JS runtime; module-level variables
// persist across that VU's iterations but are not shared with other VUs.
// ---------------------------------------------------------------------------
const N = ENDPOINTS.length;

// Start equal — no prior information.
let weights    = Array(N).fill(1 / N);
let successes  = Array(N).fill(0);
let errors     = Array(N).fill(0);
let windowStart = Date.now();

// ---------------------------------------------------------------------------
// Weight update: score = successes - PENALTY × errors, clipped to 0,
// normalised to sum 1, then epsilon floor applied for exploration.
// ---------------------------------------------------------------------------
function recomputeWeights() {
  const scores = successes.map((s, i) => Math.max(0, s - ERROR_PENALTY * errors[i]));
  const total  = scores.reduce((a, b) => a + b, 0);

  let w;
  if (total === 0) {
    w = Array(N).fill(1 / N);
  } else {
    w = scores.map(s => s / total);
  }

  // Epsilon floor: each region gets at least EPSILON weight.
  w = w.map(wi => (1 - N * EPSILON) * wi + EPSILON);

  weights   = w;
  successes = Array(N).fill(0);
  errors    = Array(N).fill(0);
  windowStart = Date.now();
}

// ---------------------------------------------------------------------------
// Weighted random pick.
// ---------------------------------------------------------------------------
function pick() {
  let r = Math.random();
  for (let i = 0; i < N; i++) {
    r -= weights[i];
    if (r <= 0) return i;
  }
  return N - 1;
}

// ---------------------------------------------------------------------------
// Main VU function.
// ---------------------------------------------------------------------------
export default function () {
  originalIterations.add(1);

  if (Date.now() - windowStart >= ADAPT_INTERVAL_MS) {
    recomputeWeights();
  }

  const idx = pick();
  const ep  = ENDPOINTS[idx];
  const url = `${ep.url}openai/deployments/${DEPLOYMENT_ID}/chat/completions?api-version=2024-02-01`;

  const t0  = Date.now();
  const res = http.post(url, PAYLOAD, {
    headers: { "Content-Type": "application/json", "api-key": ep.key, "X-Run-Id": RUN_ID },
  });

  if (res.status === 200) {
    successes[idx]++;
    eventualSuccesses.add(1);
    timeToSuccess.add(Date.now() - t0);
  } else {
    errors[idx]++;
  }

  check(res, {
    "http 200 ok":        r => r.status === 200,
    "http 429 throttled": r => r.status === 429,
    "no server error":    r => r.status < 500,
  });
}

export function handleSummary(data) {
  const path = `experiment/results/${RUN_ID}.json`;
  console.log(`Summary written to ${path}`);
  return { [path]: JSON.stringify(data, null, 2) };
}
