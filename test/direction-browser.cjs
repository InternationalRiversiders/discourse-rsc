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
        orders.push(Object.fromEntries(new URLSearchParams(route.request().postData())));
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
        const ticket = page.locator('.rsc-order-ticket'), short = ticket.locator('[data-side="short"]'), long = ticket.locator('[data-side="long"]');
        assert.equal(await ticket.locator('select').count(), 0);
        const left = await short.boundingBox(), right = await long.boundingBox();
        assert(left.x < right.x && Math.abs(left.y - right.y) < 2, 'Short left and long right on all screens');
        const info = await ticket.locator('.rsc-risk-status').boundingBox(), controls = await ticket.locator('.rsc-ticket-inputs').boundingBox();
        assert(info.y < controls.y, 'FX explanation comes before amount controls');
        const protection = await ticket.locator('.rsc-ticket-protection').boundingBox();
        assert(left.y < protection.y, 'Protection is optional and below the trading buttons');
        const colors = await ticket.locator('.rsc-submit-direction').evaluateAll(buttons => buttons.map(b => getComputedStyle(b).backgroundColor));
        assert.equal(colors[0], 'rgb(181, 47, 72)'); assert.equal(colors[1], 'rgb(20, 118, 83)');
        assert.equal(await ticket.locator('.rsc-execution-notice').getAttribute('data-mode'), 'immediate');
        assert(!(await ticket.locator('.rsc-execution-notice').innerText()).includes('15 分钟'));
        const half = ticket.locator('.rsc-allocation-buttons').getByRole('button', {name: '1/2', exact: true});
        await ticket.getByLabel('杠杆倍数', {exact: true}).fill('10');
        await half.click();
        assert.equal(await half.getAttribute('aria-pressed'), 'true');
        const quantity10 = Number(await ticket.getByLabel('数量', {exact: true}).inputValue());
        const preset25 = ticket.locator('.rsc-leverage-presets').getByRole('button', {name: '25×', exact: true});
        await preset25.click();
        assert.equal(await preset25.getAttribute('aria-pressed'), 'true');
        assert.equal(await ticket.getByLabel('杠杆倍数', {exact: true}).inputValue(), '25');
        assert.equal(await ticket.getByLabel('杠杆滑块', {exact: true}).inputValue(), '25');
        assert.equal(await half.getAttribute('aria-pressed'), 'true');
        const halfRect = await half.boundingBox(), presetRect = await preset25.boundingBox();
        assert(Math.abs(halfRect.y - presetRect.y) < 2, 'Fraction and leverage presets align');
        assert.equal(await half.evaluate(b => getComputedStyle(b).backgroundColor), await preset25.evaluate(b => getComputedStyle(b).backgroundColor), 'Hovered selection keeps its highlight');
        const quantity25 = Number(await ticket.getByLabel('数量', {exact: true}).inputValue());
        assert(Math.abs(quantity25 / quantity10 - 2.5) < .01, 'Leverage keeps the selected cash fraction, not the old quantity');
        assert((await short.innerText()).includes('余额 50.0%'));
        await ticket.screenshot({path: `${process.env.RSC_BROWSER_OUTPUT}/ticket-${scheme}-${width}.png`});
        await ticket.getByLabel('数量', {exact: true}).fill('12.34');
        assert.equal(await half.getAttribute('aria-pressed'), 'false', 'Manual edits clear the cash-fraction highlight');
        const count = orders.length;
        await ticket.getByLabel('数量', {exact: true}).press('Enter');
        await page.waitForTimeout(150);
        assert.equal(orders.length, count, 'Enter in a numeric draft must not choose a direction');
        await ticket.getByLabel('杠杆倍数', {exact: true}).fill('10');
        const submit = async (button, side) => {
          const refreshed = page.waitForResponse(r => r.url().includes('/rsc/state.json'));
          await button.click(); await refreshed;
          assert.equal(orders.at(-1).side, side);
          assert.equal(orders.at(-1).quantity, '12.34');
          assert.equal(orders.at(-1).leverage, '10');
          await page.waitForFunction(() => !document.querySelector('.rsc-submit-direction[data-side="long"]').disabled);
        };
        await submit(short, 'short');
        await submit(long, 'long');
        const take = ticket.getByLabel('止盈价（选填）', {exact: true});
        await take.fill('1.3');
        assert(await short.isDisabled(), 'A long-side take profit must not be submitted as a short');
        assert(!(await long.isDisabled()));
        assert((await ticket.locator('#rsc-order-hint-short').innerText()).includes('止盈价须小于'));
        await submit(long, 'long');
        assert.equal(orders.at(-1).take_profit, '1.3');
        await take.fill('');
        assert(!(await short.isDisabled()), 'Fields remain editable after a rejected request');
        await ticket.getByLabel('数量', {exact: true}).fill('9999999999');
        assert(await short.isDisabled() && await long.isDisabled(), 'Insufficient budget blocks both directions');
        await half.click();
        assert(!(await short.isDisabled()) && !(await long.isDisabled()));
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1));
        console.log('PASS ticket directions, payload, allocation, leverage, protections and layout', scheme, width);
      }
      // The execution notice must follow server metadata, not a fixed FX/15-minute label.
      let scenario = 'delayed';
      const patchInstrument = item => {
        if (!item || String(item.id) !== String(c.forex_id)) { return item; }
        const delayed = scenario === 'delayed', closed = scenario === 'closed';
        return {...item, category: delayed ? 'cn' : 'forex', market_closed: closed,
          execution_mode: delayed ? 'delayed_confirmation' : 'immediate',
          quote: {...item.quote, delay_seconds: delayed ? 900 : 0,
            source_time: new Date(Date.now() - (delayed ? 900000 : 7200000)).toISOString(),
            received_at: new Date().toISOString(),
            session_start: new Date(Date.now() - 3600000).toISOString(), session_end: new Date(Date.now() + 3600000).toISOString()}};
      };
      await page.route('**/rsc/state.json*', async route => {
        const response = await route.fetch({url: route.request().url().replace("rsc.test", "127.0.0.1"), headers: {...route.request().headers(), host: "rsc.test:3000"}}), data = await response.json();
        data.instruments = data.instruments?.map(patchInstrument);
        await route.fulfill({response, json: data});
      });
      await page.route('**/rsc/instruments/*/history.json*', async route => {
        const response = await route.fetch({url: route.request().url().replace("rsc.test", "127.0.0.1"), headers: {...route.request().headers(), host: "rsc.test:3000"}}), data = await response.json();
        data.instrument = patchInstrument(data.instrument);
        await route.fulfill({response, json: data});
      });
      for (scenario of ['delayed', 'stale', 'closed']) {
        await page.goto(`http://rsc.test:3000/rsc/market?instrument_id=${c.forex_id}`);
        await page.locator('.rsc-open-order').click();
        const ticket = page.locator('.rsc-order-ticket');
        const notice = await ticket.locator('.rsc-execution-notice').innerText();
        if (scenario === 'delayed') {
          assert(notice.includes('延时成交') && notice.includes('15 分钟') && notice.includes('提交后产生'));
          assert.equal(await ticket.locator('.rsc-leverage-presets button').last().innerText(), '10×');
        } else if (scenario === 'stale') {
          assert(notice.includes('先刷新并核验报价') && !notice.includes('15 分钟'));
          assert(!(await ticket.locator('[data-side="short"]').isDisabled()), 'Stale FX can request a fresh execution quote');
        } else {
          assert(await ticket.locator('[data-side="short"]').isDisabled());
          assert(await ticket.locator('[data-side="long"]').isDisabled());
          assert((await ticket.innerText()).includes('当前休市'));
        }
      }
      await page.unroute('**/rsc/state.json*');
      await page.unroute('**/rsc/instruments/*/history.json*');
      console.log('PASS delayed, stale and closed quote feedback', scheme);
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
