// Translate structured codes using the browser locale, not the server's locale.
const knownCodes = new Set([
  "forecast_liquidity",
  "forecast_stale",
  "forecast_quote_expired",
  "forecast_closed",
  "forecast_unavailable",
  "forecast_limit",
  "forecast_shares",
  "forecast_disabled",
  "forecast_not_eligible",
  "forecast_invalid_reference",
  "forecast_ai_unconfigured",
  "insufficient_balance",
  "wallet_frozen",
  "read_only",
  "membership_required",
  "invalid_amount",
  "invalid_pick",
  "idempotency_conflict",
  "provider_cooldown",
  "provider_busy",
  "provider_unavailable"
]);

export function forecastErrorKey(error) {
  const response = error?.jqXHR || error;
  const code = response?.responseJSON?.error_code;
  if (knownCodes.has(code)) {
    return `error_${code}`;
  }
  if (response?.status === 429) {
    return "error_rate_limited";
  }
  return "error_request_failed";
}
