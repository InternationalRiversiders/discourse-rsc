const assert = require('node:assert/strict');
const fs = require('node:fs');
const { chromium } = require(process.env.RSC_PLAYWRIGHT);
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.RSC_CHROMIUM, args: ['--no-sandbox'] });
  try {
    for (const [base, path, readOnly] of [
      ['http://127.0.0.1:13000', '/opt/rsc-private-preview/snapshot-login.json', true],
      ['http://localhost:13001', '/opt/rsc-private-preview/demo-login.json', false],
    ]) {
      const credentials = JSON.parse(fs.readFileSync(path, 'utf8'));
      const context = await browser.newContext({ viewport: { width: 1440, height: 1000 } });
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', e => errors.push(e.message));
      await page.goto(base + '/login');
      const loggedIn = await page.evaluate(async ({ username, password }) => {
        const csrf = await (await fetch('/session/csrf.json')).json();
        const response = await fetch('/session.json', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf.csrf }, body: JSON.stringify({ login: username, password }) });
        const body = await response.json(); return { ok: response.ok && !body.error, status: response.status, error: body.error || null }; 
      }, credentials);
      assert(loggedIn.ok, `Private test login: ${loggedIn.status} ${loggedIn.error || ''}`);
      await page.goto(base + '/rsc/market');
      await page.locator('.rsc-market-board').waitFor();
      const state = await page.evaluate(async () => (await fetch('/rsc/state.json')).json());
      assert.equal(state.read_only, readOnly);
      if (readOnly) {
        const expected = JSON.parse(fs.readFileSync(process.env.RSC_PRIVATE_SNAPSHOT_EXPECTATIONS || '/opt/rsc-private-preview/snapshot-expectations.json', 'utf8'));
        assert.equal(state.instruments.length, 1638);
        assert.equal(state.instruments[0].symbol, 'CRYPTO:BTC/USD');
        const board = page.locator('.rsc-market-board');
        assert.equal(await board.getByLabel('行情排序').inputValue(), 'popular');
        assert.equal(await board.locator('.rsc-quote-row').count(), 20);
        const firstSymbol = await board.locator('.rsc-quote-row').first().getAttribute('aria-label');
        assert.equal(firstSymbol, 'CRYPTO:BTC/USD');
        await board.getByRole('button', { name: '下一页', exact: true }).click();
        assert.notEqual(await board.locator('.rsc-quote-row').first().getAttribute('aria-label'), firstSymbol);
        await page.getByRole('status').filter({ hasText: '只读预览' }).waitFor();
        const blocked = await page.evaluate(async () => {
          const csrf = await (await fetch('/session/csrf.json')).json();
          return (await fetch('/rsc/transfers.json', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf.csrf }, body: JSON.stringify({ recipient_username: 'nobody', amount: '1', request_id: 'private-readonly-test' }) })).status;
        });
        assert.equal(blocked, 503);
        const chart = await page.evaluate(async (items) => {
          for (const item of items.filter(i => i.history.length > 1).slice(0, 10)) {
            const response = await fetch(`/rsc/instruments/${item.id}/history.json?range=1d`);
            if (response.ok) { const result = await response.json(); return result.archived && result.currency === 'RSC' && result.candles.length > 1; }
          }
          return false;
        }, state.instruments);
        assert(chart, 'Real archived chart is available');
        await page.goto(base + '/rsc/leaderboard');
        await page.getByRole('button', { name: expected.leader_username, exact: true }).waitFor();
        const firstRank = page.locator('tbody tr').first();
        assert((await firstRank.innerText()).includes(expected.leader_username));
        assert((await firstRank.innerText()).includes(expected.leader_display_amount));
        assert.equal(await firstRank.locator(`[title="${expected.leader_exact_amount}"]`).count(), 1);
        await page.setViewportSize({ width: 390, height: 844 });
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 2));
        await page.setViewportSize({ width: 1440, height: 1000 });
        await page.goto(base + '/rsc/admin');
        await page.getByRole('button', { name: '检查活动', exact: true }).click();
        await page.getByRole('button', { name: '补发缺失奖励', exact: true }).waitFor();
        const campaign = await page.evaluate(async () => (await fetch('/rsc/admin/campaign.json')).json());
        assert.equal(campaign.participants, 206);
        assert.equal(campaign.pending, 0);
        assert(await page.getByRole('button', { name: '补发缺失奖励', exact: true }).isDisabled());
        const ranking = await page.evaluate(async () => (await fetch('/rsc/ranking.json?sort=equity&page=2')).json());
        assert(ranking.pagination.total > 20);
        assert.equal(ranking.pagination.page, 2);
        console.log('PASS private snapshot login, popular order/20-row pagination, snapshot leader/4-decimal truncation/mobile layout, 1638 active instruments, archived chart, 206 campaign awards retained, pagination and read-only HTTP protection');
      } else {
        assert.equal(state.demo, true);
        assert.equal(state.instruments.length, 12);
        console.log('PASS private demo login and isolated synthetic data');
      }
      assert.deepEqual(errors, []);
      await context.close();
    }
  } finally { await browser.close(); }
})().catch(e => { console.error(e.message); process.exit(1); });
