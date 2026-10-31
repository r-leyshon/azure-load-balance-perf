import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Trend } from "k6/metrics";

// All configuration comes from environment variables — no values hardcoded.
const BASE_URL        = __ENV.APIM_GATEWAY_URL;
const APIM_KEY        = __ENV.APIM_SUBSCRIPTION_KEY;
const DEPLOYMENT_ID   = __ENV.DEPLOYMENT_ID  || "chat";
const RUN_ID          = __ENV.RUN_ID         || "unnamed";
const VUS             = parseInt(__ENV.VUS   || "20");
const ITER            = parseInt(__ENV.ITER  || "200");

// Retry configuration — strategy applies to 429 responses only.
// none | immediate | fixed | backoff | backoff_jitter | retry_after
const RETRY_STRATEGY  = __ENV.RETRY_STRATEGY || "none";
const MAX_RETRIES     = parseInt(__ENV.MAX_RETRIES    || "3");
const RETRY_DELAY_MS  = parseInt(__ENV.RETRY_DELAY_MS || "500");
// Set DURATION (e.g. "5m") for time-boxed sustained runs instead of iteration-based.
const DURATION        = __ENV.DURATION || null;

if (!BASE_URL) throw new Error("APIM_GATEWAY_URL env var is required");
if (!APIM_KEY) throw new Error("APIM_SUBSCRIPTION_KEY env var is required");

export const options = DURATION
  ? { vus: VUS, duration: DURATION, summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"] }
  : { vus: VUS, iterations: ITER,  summaryTrendStats: ["avg", "p(50)", "p(95)", "p(99)", "max"] };

// Custom metrics for retry-aware success accounting.
// eventual_successes counts original requests that eventually got HTTP 200.
// total_http_calls counts every HTTP call made (originals + retries).
// time_to_success records wall-clock ms from first attempt to 200 (retries inclusive).
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

// Returns delay in ms for the given attempt number (1-indexed) and strategy.
// retryAfterMs is the value parsed from the Retry-After response header (may be 0).
function retryDelayMs(attempt, retryAfterMs) {
  switch (RETRY_STRATEGY) {
    case "immediate":
      return 0;
    case "fixed":
      return RETRY_DELAY_MS;
    case "backoff":
      return RETRY_DELAY_MS * Math.pow(2, attempt - 1);
    case "backoff_jitter": {
      const base = RETRY_DELAY_MS * Math.pow(2, attempt - 1);
      return base * (0.5 + Math.random());   // ±50% uniform jitter
    }
    case "retry_after":
      return retryAfterMs > 0 ? retryAfterMs : RETRY_DELAY_MS;
    default:
      return 0;
  }
}

// Parse Retry-After header value into milliseconds.
// Azure returns an integer number of seconds.
function parseRetryAfter(res) {
  const raw = res.headers["Retry-After"] || res.headers["retry-after"] || "0";
  const secs = parseInt(raw, 10);
  return isNaN(secs) ? 0 : secs * 1000;
}

export default function () {
  originalIterations.add(1);
  const startMs = Date.now();
  let attempts  = 0;
  let succeeded = false;
  let lastRes;

  do {
    attempts++;
    lastRes = http.post(URL, PAYLOAD, { headers: HEADERS });
    totalHttpCalls.add(1);

    if (lastRes.status === 200) {
      succeeded = true;
      break;
    }

    if (lastRes.status === 429 && RETRY_STRATEGY !== "none" && attempts <= MAX_RETRIES) {
      const delay = retryDelayMs(attempts, parseRetryAfter(lastRes));
      if (delay > 0) sleep(delay / 1000);
      continue;
    }

    // Non-429 failure or no retry — stop.
    break;
  } while (attempts <= MAX_RETRIES);

  if (succeeded) {
    eventualSuccesses.add(1);
    timeToSuccess.add(Date.now() - startMs);
  }

  check(lastRes, {
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
