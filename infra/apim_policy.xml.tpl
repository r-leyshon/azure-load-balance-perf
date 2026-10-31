<policies>
  <inbound>
    <base />
    <authentication-managed-identity resource="https://cognitiveservices.azure.com" />
    <rate-limit-by-key
      calls="${gateway_rpm_limit}"
      renewal-period="60"
      counter-key="@(context.Subscription.Id)"
      remaining-calls-variable-name="remainingCalls" />
    <set-backend-service backend-id="foundry-pool" />
  </inbound>

  <backend>
%{ if apim_retry_count > 0 ~}
    <retry condition="@(context.Response.StatusCode == 429)"
           count="${apim_retry_count}"
           interval="${apim_retry_interval_s}"
           first-fast-retry="false">
      <set-backend-service backend-id="foundry-pool" />
    </retry>
%{ else ~}
    <base />
%{ endif ~}
  </backend>

  <outbound>
    <base />
    <emit-metric name="foundry-request" value="1" namespace="foundry-perf">
      <dimension name="run_id"
        value="@(context.Request.Headers.GetValueOrDefault(&quot;X-Run-Id&quot;, &quot;unknown&quot;))" />
      <dimension name="status_code"
        value="@(context.Response.StatusCode.ToString())" />
    </emit-metric>
  </outbound>

  <on-error>
    <base />
  </on-error>
</policies>
