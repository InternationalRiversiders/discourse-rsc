import assert from "node:assert/strict";
import fs from "node:fs";

const repos = ["rsc", "alumni-map", "course-review", "rsdate", "whisper", "seek"];
const sources = repos.map(name => fs.readFileSync(`/opt/discourse-${name}/assets/javascripts/discourse/lib/campus-time.js`, "utf8"));
sources.forEach(source => assert.equal(source, sources[0], "Campus plugins must use identical date rules"));
const time = await import("data:text/javascript;base64," + Buffer.from(sources[0]).toString("base64"));
const originalZone = process.env.TZ;
const nativeIntl = globalThis.Intl;
try {
  for (const [zone, expected] of [["UTC", "23:30:00"], ["Asia/Shanghai", "07:30:00"], ["America/New_York", "19:30:00"]]) {
    process.env.TZ = zone;
    assert.equal(time.browserTimeZone(), zone);
    assert.ok(time.formatTime("2026-09-21T23:30:00Z").includes(expected), zone);
    assert.equal(time.formatDate("2026-09-21"), "2026-09-21", "calendar dates must not shift");
  }
  process.env.TZ = "America/New_York";
  assert.ok(time.formatTime("2026-01-21T23:30:00Z").includes("18:30:00"), "winter DST offset");
  assert.equal(time.asDate("2026-09-22 07:30:00").toISOString(), "2026-09-21T23:30:00.000Z");
  assert.equal(time.formatDateTime(null), "—");
  assert.equal(time.formatDateTime("invalid date"), "—");
  for (const missing of [undefined, "", "Invalid/Timezone"]) {
    globalThis.Intl = { DateTimeFormat: function(locale, options) {
      return options ? new nativeIntl.DateTimeFormat(locale, options) : { resolvedOptions: () => ({timeZone: missing}) };
    }};
    assert.equal(time.browserTimeZone(), "Asia/Shanghai");
    assert.ok(time.formatTime("2026-09-21T23:30:00Z").includes("07:30:00"));
  }
  globalThis.Intl = undefined;
  assert.equal(time.formatDateTime("2026-09-21T23:30:00Z"), "2026-09-22 07:30:00");
  assert.equal(time.formatDate("2026-09-21T23:30:00Z"), "2026-09-22");
  console.log("Six plugins: browser zones, UTC, DST, missing/invalid zone, missing Intl, naive timestamps and calendar dates passed");
} finally {
  globalThis.Intl = nativeIntl;
  if (originalZone === undefined) { delete process.env.TZ; } else { process.env.TZ = originalZone; }
}
