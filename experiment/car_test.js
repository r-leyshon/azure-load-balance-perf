import http from "k6/http";
import { check } from "k6";
import { Counter, Trend } from "k6/metrics";

// All configuration comes from environment variables — no values hardcoded.
const BASE_URL      = __ENV.APIM_GATEWAY_URL;
const APIM_KEY      = __ENV.APIM_SUBSCRIPTION_KEY;
const DEPLOYMENT_ID = __ENV.DEPLOYMENT_ID  || "chat";
const RUN_ID        = __ENV.RUN_ID         || "unnamed";
const RATE_PER_S    = parseInt(__ENV.RATE_PER_S    || "10");
const DURATION      = __ENV.DURATION               || "5m";
const PRE_ALLOC_VUS = parseInt(__ENV.PRE_ALLOC_VUS || "30");
const MAX_VUS       = parseInt(__ENV.MAX_VUS        || "60");

if (!BASE_URL) throw new Error("APIM_GATEWAY_URL env var is required");
if (!APIM_KEY) throw new Error("APIM_SUBSCRIPTION_KEY env var is required");

// Constant-arrival-rate executor: fires requests at a fixed rate regardless of
// how long they take. Unlike closed-loop VU tests, fast failures (503s from a
// tripped CB) do not increase offered load — each iteration slot fires at the
// same wall-clock rate. This removes the confound where tripped-CB configs
// receive ~2× more HTTP calls than slow-failure configs in the same wall-clock
// window.
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

// Same custom metrics as load_test.js for consistent summarise.py parsing.
const eventualSuccesses  = new Counter("eventual_successes");
const totalHttpCalls     = new Counter("total_http_calls");
const timeToSuccess      = new Trend("time_to_success", true);
const originalIterations = new Counter("original_iterations");

const PAYLOAD = JSON.stringify({
  messages: [{ role: "user", content: "Reply with exactly one word: Hello." }],
  max_tokens: 5,
});

const HEADERS = {
  "Content-Type":               "application/json",
  "Ocp-Apim-Subscription-Key": APIM_KEY,
  "X-Run-Id":                   RUN_ID,
};

const URL = `${BASE_URL}/openai/deployments/${DEPLOYMENT_ID}/chat/completions?api-version=2024-02-01`;

export default function () {
  originalIterations.add(1);
  const startMs = Date.now();

  const res = http.post(URL, PAYLOAD, { headers: HEADERS });
  totalHttpCalls.add(1);

  // Validate body on 200s to confirm real completions (not synthetic gateway responses).
  let bodyValid = false;
  if (res.status === 200) {
    try {
      const body = JSON.parse(res.body);
      bodyValid = Array.isArray(body.choices) && body.choices.length > 0;
    } catch { /* non-JSON 200 — treat as failure */ }
  }

  check(res, {
    "http 200 ok":        (r) => r.status === 200,
    "body has choices":   () => res.status !== 200 || bodyValid,
    "http 429 throttled": (r) => r.status === 429,
    "no server error":    (r) => r.status < 500,
  });

  if (bodyValid) {
    eventualSuccesses.add(1);
    timeToSuccess.add(Date.now() - startMs);
  }
}

export function handleSummary(data) {
  const path = `experiment/results/${RUN_ID}.json`;
  console.log(`Summary written to ${path}`);
  return { [path]: JSON.stringify(data, null, 2) };
}
