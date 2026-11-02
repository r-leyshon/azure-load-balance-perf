import http from "k6/http";
import { check } from "k6";
import { Counter, Trend } from "k6/metrics";

// All configuration comes from environment variables — no values hardcoded.
const DEPLOYMENT_ID = __ENV.DEPLOYMENT_ID  || "chat";
const RUN_ID        = __ENV.RUN_ID         || "unnamed";
const RATE_PER_S    = parseInt(__ENV.RATE_PER_S    || "2");
const DURATION      = __ENV.DURATION               || "5m";
const PRE_ALLOC_VUS = parseInt(__ENV.PRE_ALLOC_VUS || "30");
const MAX_VUS       = parseInt(__ENV.MAX_VUS        || "60");

// Endpoints tried in order (sequential fallback: UK South → West Europe → Sweden Central).
// Direct Foundry calls via API keys — no APIM.
const ENDPOINTS = [
  { url: __ENV.FOUNDRY_ENDPOINT_UKSOUTH,       key: __ENV.FOUNDRY_KEY_UKSOUTH,       region: "uksouth" },
  { url: __ENV.FOUNDRY_ENDPOINT_WESTEUROPE,    key: __ENV.FOUNDRY_KEY_WESTEUROPE,    region: "westeurope" },
  { url: __ENV.FOUNDRY_ENDPOINT_SWEDENCENTRAL, key: __ENV.FOUNDRY_KEY_SWEDENCENTRAL, region: "swedencentral" },
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

export default function () {
  originalIterations.add(1);
  const startMs = Date.now();
  let finalRes;
  let bodyValid = false;

  // Sequential fallback: UK South first, then West Europe, then Sweden Central.
  // Moves to the next region on any non-200 response (429, 5xx, etc.).
  for (const ep of ENDPOINTS) {
    const res = http.post(buildUrl(ep), PAYLOAD, { headers: buildHeaders(ep) });
    finalRes = res;
    if (res.status === 200) {
      try {
        const body = JSON.parse(res.body);
        bodyValid = Array.isArray(body.choices) && body.choices.length > 0;
      } catch { /* non-JSON 200 */ }
      break;
    }
  }

  if (bodyValid) {
    eventualSuccesses.add(1);
    timeToSuccess.add(Date.now() - startMs);
  }

  check(finalRes, {
    "http 200 ok":        (r) => r.status === 200,
    "body has choices":   () => finalRes.status !== 200 || bodyValid,
    "http 429 throttled": (r) => r.status === 429,
    "no server error":    (r) => r.status < 500,
  });
}

export function handleSummary(data) {
  const path = `experiment/results/${RUN_ID}.json`;
  console.log(`Summary written to ${path}`);
  return { [path]: JSON.stringify(data, null, 2) };
}
