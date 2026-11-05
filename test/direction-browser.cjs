// Isolated forum only: intercept order submissions and check the actual payload.
const assert = require('node:assert/strict'), fs = require('node:fs');
const { chromium } = require(process.env.RSC_PLAYWRIGHT);
(async () => {
  const c = JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
  const browser = await chromium.launch({executablePath: process.env.RSC_CHROMIUM, args: ['--no-sandbox', '--host-resolver-rules=MAP rsc.test 127.0.0.1', '--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000']});
  try {
    for (const scheme of ['light', 'dark']) {
      const context = await browser.newContext({viewport: {width: 1440, height: 1000}, locale: 'zh-CN', colorScheme: scheme});
      const page = await context.newPage(), errors = [], orders = [];
      page.on('pageerror', e => errors.push(e.message));
      await page.route('**/rsc/orders.json', async route => {
        if (route.request().method() !== 'POST') { return route.continue(); }
        orders.push(new URLSearchParams(route.request().postData()).get('side'));
        await route.fulfill({status: 200, contentType: 'application/json', body: JSON.stringify({status: 'rejected'})});
      });
      await page.goto('http://rsc.test:3000/login', {waitUntil: 'networkidle'});
      assert.equal(await page.evaluate(async c => {
        // The login page may refresh its session for a passkey challenge.
        for (let attempt = 0; attempt < 2; attempt++) {
          const csrf = await (await fetch('/session/csrf.json')).json();
          const response = await fetch('/session.json', {method: 'POST', headers: {'Content-Type': 'application/json', 'X-CSRF-Token': csrf.csrf, 'X-Requested-With': 'XMLHttpRequest'}, body: JSON.stringify({login: c.username, password: c.password})});
          if (response.status !== 403 || attempt === 1) { return response.status; }
        }
      }, c), 200);
      for (const width of [1440, 390, 320]) {
        await page.setViewportSize({width, height: 1000});
        await page.goto(`http://rsc.test:3000/rsc/market?instrument_id=${c.forex_id}`);
        await page.locator('.rsc-open-order').click();
        const ticket = page.locator('.rsc-order-ticket'), short = ticket.locator('.rsc-direction-short'), long = ticket.locator('.rsc-direction-long');
        assert.equal(await ticket.locator('select').count(), 0);
        const left = await short.boundingBox(), right = await long.boundingBox();
        assert(left.x < right.x && Math.abs(left.y - right.y) < 2, 'Short left and long right on all screens');
        const info = await ticket.locator('.rsc-risk-status').boundingBox(), controls = await ticket.locator('.rsc-ticket-inputs').boundingBox();
        assert(info.y < controls.y, 'FX explanation comes before amount controls');
        await ticket.getByLabel('数量', {exact: true}).fill('12.34');
        await ticket.getByLabel('杠杆倍数', {exact: true}).fill('10');
        const count = orders.length;
        await short.focus(); await page.keyboard.press('Space');
        assert.equal(orders.length, count, 'Selecting direction must not submit');
        assert.equal(await short.getAttribute('aria-pressed'), 'true');
        assert.equal(await long.getAttribute('aria-pressed'), 'false');
        assert.equal(await ticket.getByLabel('数量', {exact: true}).inputValue(), '12.34');
        assert.equal(await ticket.getByLabel('杠杆倍数', {exact: true}).inputValue(), '10');
        assert((await ticket.locator('[type=submit]').innerText()).includes('做空'));
        await ticket.screenshot({path: `${process.env.RSC_BROWSER_OUTPUT}/ticket-${scheme}-${width}.png`});
        await ticket.locator('[type=submit]').click();
        await page.waitForResponse(r => r.url().includes('/rsc/state.json'));
        assert.equal(orders.at(-1), 'short');
        await long.click();
        assert.equal(await long.getAttribute('aria-pressed'), 'true');
        assert((await ticket.locator('[type=submit]').innerText()).includes('做多'));
        await ticket.locator('[type=submit]').click();
        await page.waitForResponse(r => r.url().includes('/rsc/state.json'));
        assert.equal(orders.at(-1), 'long');
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
        console.log('PASS direction, payload, draft preservation and layout', scheme, width);
      }
      await page.goto('http://rsc.test:3000/rsc/leaderboard');
      await page.locator('.rsc-ranking-table tbody tr').filter({hasText: c.username}).first().locator('.rsc-trader-link').click();
      await page.locator('.rsc-performance svg').waitFor();
      const metrics = await page.evaluate(async id => {
        const current = await (await fetch(`/rsc/traders/${id}.json?performance_metric=realized_pnl`)).json();
        const compatible = await (await fetch(`/rsc/traders/${id}.json`)).json();
        return {unit: current.performance.unit, source: compatible.performance.source};
      }, c.user_id);
      assert.equal(metrics.unit, 'RSC');
      assert.equal(metrics.source, 'legacy_flow_boundaries', 'Existing percentage clients keep their contract');
      assert(!(await page.locator('.rsc-performance').innerText()).includes('旧系统'));
      assert((await page.locator('.rsc-chart-axis').innerText()).includes('RSC'));
      await page.getByRole('button', {name: '近3天', exact: true}).click();
      await page.locator('.rsc-performance svg').waitFor();
      await page.locator('.rsc-trader-detail').screenshot({path: `${process.env.RSC_BROWSER_OUTPUT}/ranking-${scheme}.png`});
      assert.deepEqual(errors, []);
      await context.close();
    }
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
