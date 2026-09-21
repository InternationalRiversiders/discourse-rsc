/* Read-only checks on the retained private forums; never prints user records. */
const assert = require("node:assert/strict");
const fs = require("node:fs");
const { chromium } = require(process.env.RSC_PLAYWRIGHT);
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.RSC_CHROMIUM, args: ["--no-sandbox"] });
  try {
    for (const [base, file, readOnly] of [
      ["http://127.0.0.1:13000", "/opt/rsc-private-preview/snapshot-login.json", true],
      ["http://localhost:13001", "/opt/rsc-private-preview/demo-login.json", false],
    ]) {
      const saved = JSON.parse(fs.readFileSync(file, "utf8"));
      const credentials = readOnly ? saved : saved.admin;
      const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
      const page = await context.newPage();
      const errors = [];
      page.on("pageerror", error => errors.push(error.message));
      await page.goto(`${base}/login`);
      const ok = await page.evaluate(async ({ username, password }) => {
        const csrf = await (await fetch("/session/csrf.json")).json();
        const response = await fetch("/session.json", { method: "POST", headers: { "Content-Type": "application/json", "X-CSRF-Token": csrf.csrf }, body: JSON.stringify({ login: username, password }) });
        return response.ok && !(await response.json()).error;
      }, credentials);
      assert(ok, "Private admin login succeeds");
      await page.goto(`${base}/rsc/admin`);
      await page.locator(".rsc-admin-tools").waitFor();
      assert.equal(await page.locator('.rsc-tabs').count(), 1);
      assert.equal(await page.locator('.rsc-tabs a.active').innerText(), 'RSC 管理');
      await page.locator('.rsc-tabs').getByRole('link', {name:'排行榜',exact:true}).click();
      await page.locator('.rsc-ranking-page').waitFor();
      assert.equal(await page.locator('.rsc-tabs a.active').innerText(), '排行榜');
      await page.locator('.rsc-tabs').getByRole('link', {name:'股市',exact:true}).click();
      await page.locator('.rsc-market-board').waitFor();
      await page.locator('.rsc-tabs').getByRole('link', {name:'RSC 管理',exact:true}).click();
      await page.locator('.rsc-admin-tools').waitFor();
      const results = await page.evaluate(async () => {
        const result = {};
        for (const kind of ["all", "transfer", "post_tip", "red_packet", "issuance", "admin_adjustment"]) {
          const response = await fetch(`/rsc/admin/activity.json?kind=${kind}`);
          const body = await response.json();
          result[kind] = { status: response.status, total: body.pagination?.total, rows: body.rows?.length };
        }
        const response = await fetch("/rsc/admin/search-demand.json");
        const body = await response.json();
        result.demand = { status: response.status, total: body.pagination?.total };
        result.wallet = (await fetch("/rsc/state.json")).status;
        return result;
      });
      for (const [name, result] of Object.entries(results)) {
        if (name === "wallet") { assert.equal(result, 200); continue; }
        assert.equal(result.status, 200, `${name} query succeeds`);
        assert(Number.isInteger(result.total));
        if (result.rows !== undefined) { assert(result.rows <= 20); }
      }
      if (readOnly) {
        assert(results.issuance.total > 0, "Historical issuance is included");
        assert(results.demand.total > 0, "Historical search demand is included");
        assert(await page.getByRole("button", { name: "立即检查并结算", exact: true }).isDisabled());
      }
      const panel = page.locator(".rsc-admin-tools");
      await panel.getByLabel("资金类型", { exact: true }).selectOption("post_tip");
      await panel.getByRole("button", { name: "查询资金记录", exact: true }).click();
      await panel.locator("tbody tr").first().waitFor();
      await page.getByRole("button", { name: "查看搜索需求统计", exact: true }).click();
      await page.locator(".rsc-admin-approval table").waitFor();
      await page.setViewportSize({ width: 390, height: 844 });
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 2));
      assert.equal(await page.locator('.rsc-tabs a').count(), 5);
      for (const link of await page.locator('.rsc-tabs a').all()) { assert(await link.isVisible()); }
      assert.deepEqual(errors, []);
      console.log(`PASS private ${readOnly ? "snapshot" : "demo"} admin: wallet access, six activity filters, search demand, responsive UI${readOnly ? ", read-only guard" : ""}`);
      await context.close();
    }
  } finally { await browser.close(); }
})().catch(error => { console.error(error.message); process.exitCode = 1; });
