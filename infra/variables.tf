variable "subscription_id" {
  type      = string
  sensitive = true
}

variable "resource_group_name" {
  type    = string
  default = "rg-apim-foundry-perf"
}

variable "apim_location" {
  type    = string
  default = "uksouth"
}

variable "publisher_name" {
  type = string
}

variable "publisher_email" {
  type      = string
  sensitive = true
}

variable "model_name" {
  type    = string
  default = "gpt-4.1-mini"
}

variable "model_version" {
  type    = string
  default = "2025-04-14"
}

# Capacity in thousands of TPM per Foundry backend.
# 10 = 10 000 TPM — easily saturated by ~20 concurrent VUs at ~500 tokens/request.
variable "quota_tpm" {
  type    = number
  default = 10000
}

# --- Per-experiment-run variables (overridden between iterations) ---

# Gateway-level call rate limit (requests per minute) applied by rate-limit-by-key policy.
# Set high to let Foundry backend quotas saturate first; lower to test gateway throttling.
variable "gateway_rpm_limit" {
  type    = number
  default = 10000
}

# Number of failures within the evaluation window before a backend's circuit breaker trips.
# Set to 0 to disable circuit breakers entirely.
variable "circuit_breaker_failure_count" {
  type    = number
  default = 0
}

# Whether 429 responses count as circuit-breaker failures.
# true  = trip on 429 OR 5xx (quota exhaustion treated as a failure signal — good for regional saturation)
# false = trip on 5xx only  (quota exhaustion ignored — CB only reacts to hard service errors)
variable "circuit_breaker_on_429" {
  type    = bool
  default = true
}

# Relative weights for the backend pool.
# Values are proportional — only the ratios matter, not the absolute numbers.
variable "backend_weight_uksouth" {
  type    = number
  default = 33
}

variable "backend_weight_westeurope" {
  type    = number
  default = 33
}

variable "backend_weight_swedencentral" {
  type    = number
  default = 34
}

# Number of times APIM retries a 429 response against the backend pool before
# returning the error to the caller. Set to 0 to disable server-side retry.
variable "apim_retry_count" {
  type    = number
  default = 0
}

# Seconds between APIM server-side retry attempts.
variable "apim_retry_interval_s" {
  type    = number
  default = 1
}

# Priority assigned to the two fallback backends (westeurope, swedencentral) in the pool.
# 1 = same priority as UK South → weighted pool (all requests distributed by weight).
# 2 = lower priority than UK South → priority pool (all requests go to UK South first;
#     fallbacks only receive traffic when UK South's CB has tripped).
variable "backend_priority_fallback" {
  type    = number
  default = 1
}
