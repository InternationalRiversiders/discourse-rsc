import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const source = readFileSync(new URL("../assets/javascripts/discourse/lib/rsc-forecast-error.js", import.meta.url), "utf8");
const { forecastErrorKey } = await import(`data:text/javascript,${encodeURIComponent(source)}`);
for (const code of ["forecast_probability_range", "forecast_stale", "forecast_liquidity", "forecast_quote_expired"]) {
  const response = { responseJSON: { error_code: code, errors: ["English server error"] }, status: 409 };
  assert.equal(forecastErrorKey(response), `error_${code}`);
  assert.equal(forecastErrorKey({ jqXHR: response }), `error_${code}`);
  for (const locale of ["zh_CN", "en"]) {
    const translations = readFileSync(new URL(`../config/locales/client.${locale}.yml`, import.meta.url), "utf8");
    assert.ok(translations.includes(`error_${code}:`));
  }
}
assert.equal(forecastErrorKey({ status: 429 }), "error_rate_limited");
assert.equal(forecastErrorKey({ jqXHR: { status: 429 } }), "error_rate_limited");
assert.equal(forecastErrorKey({ responseJSON: { error_code: "unknown", errors: ["<html>failure</html>"] } }), "error_request_failed");
assert.equal(forecastErrorKey(null), "error_request_failed");
console.log("Forecast error mapping checks passed");
