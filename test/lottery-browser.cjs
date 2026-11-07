const assert = require('node:assert/strict'), fs = require('node:fs');
const { chromium } = require(process.env.RSC_PLAYWRIGHT);
(async () => {
  const c = JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
  const browser = await chromium.launch({ executablePath: process.env.RSC_CHROMIUM, args: ['--no-sandbox', '--host-resolver-rules=MAP rsc.test 127.0.0.1', '--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000'] });
  const context = await browser.newContext({ viewport: { width: 1360, height: 1100 }, locale: 'zh-CN' });
  const page = await context.newPage(), errors = [];
  page.on('pageerror', e => errors.push(e.message));
  async function login(credentials) {
    await page.goto('http://rsc.test:3000/login', { waitUntil: 'networkidle' });
    const status = await page.evaluate(async c => {
      for (let i = 0; i < 2; i++) {
        const { csrf } = await (await fetch('/session/csrf.json')).json();
        const r = await fetch('/session.json', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf, 'X-Requested-With': 'XMLHttpRequest' }, body: JSON.stringify({ login: c.username, password: c.password }) });
        if (r.status !== 403 || i === 1) { return r.status; }
      }
    }, credentials);
    assert.equal(status, 200);
  }
  try {
    await login(c);
    await page.goto('http://rsc.test:3000/rsc/games');
    await page.locator('.rl-banner').waitFor();
    assert.equal(await page.locator('.rg-game-card').count(), 6);
    const links = (await page.locator('[data-section-name="campus-life"] a.sidebar-section-link').allTextContents()).map(t => t.trim());
    assert(links.indexOf('树洞') >= 0, JSON.stringify(links));
    assert.equal(links.indexOf('游戏'), links.indexOf('树洞') + 1, 'Games follows whisper');
    const banner = await page.locator('.rl-banner').boundingBox(), cards = await page.locator('.rg-lobby').boundingBox();
    assert(banner.y + banner.height <= cards.y);
    await page.locator('.rg-app').screenshot({ path: `${process.env.RSC_BROWSER_OUTPUT}/lottery-banner.png` });
    await page.locator('.rl-banner').click();
    await page.locator('#rl-number').waitFor();
    assert.equal(await page.locator('.rl-accounting').count(), 0, 'No admin accounting for members');
    for (const width of [1360, 390, 320]) {
      await page.setViewportSize({ width, height: 1100 });
      await page.locator('.rl-page').screenshot({ path: `${process.env.RSC_BROWSER_OUTPUT}/lottery-${width}.png` });
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), `Fits ${width}`);
    }
    await page.locator('#rl-number').fill('0012');
    await page.locator('#rl-quantity').fill('2');
    await page.locator('.rl-submit').click();
    await page.locator('.rl-success').waitFor();
    assert((await page.locator('.rl-success').innerText()).includes('0012 × 2'));
    await page.locator('.rl-ticket').first().waitFor();
    assert.equal(await page.locator('.rl-ticket').count(), 1);
    assert((await page.locator('.rl-ticket').innerText()).includes('0012'));
    // Lose the response after a real committed purchase, then reload and retry.
    await page.locator('#rl-number').fill('7890');
    await page.locator('#rl-quantity').fill('1');
    await page.route('**/rsc/lottery/buy.json', async route => {
      const response = await route.fetch({ url: 'http://127.0.0.1:3000/rsc/lottery/buy.json', headers: { ...route.request().headers(), host: 'rsc.test:3000' } });
      assert.equal(response.status(), 200);
      await route.fulfill({ status: 502, contentType: 'application/json', body: '{"errors":["gateway"]}' });
    }, { times: 1 });
    await page.locator('.rl-submit').click();
    await page.locator('.rl-error').waitFor();
    assert((await page.locator('.rl-submit').innerText()).includes('同一笔'));
    await page.reload();
    await page.getByRole('button', { name: '确认同一笔购票', exact: true }).waitFor();
    assert(await page.locator('#rl-number').isDisabled());
    await page.locator('.rl-submit').click();
    await page.locator('.rl-success').waitFor();
    await page.waitForFunction(() => document.querySelectorAll('.rl-ticket').length === 2);
    assert.equal(await page.locator('.rl-ticket').count(), 2, 'Replay does not create an extra ticket');
    const checks = await page.evaluate(async () => {
      const state = await (await fetch('/rsc/lottery/state.json')).json();
      const { csrf } = await (await fetch('/session/csrf.json')).json();
      const body = { draw_id: state.current.id, number: '9999', quantity: 20, request_id: crypto.randomUUID(), user_id: -1, payout: '999999' };
      const send = token => fetch('/rsc/lottery/buy.json', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': token }, body: JSON.stringify(body) });
      const noCsrf = await send('invalid'), over = await send(csrf), error = await over.json();
      const after = await (await fetch('/rsc/lottery/state.json')).json();
      return { state, after, csrf: noCsrf.status, over: over.status, error };
    });
    assert.equal(checks.csrf, 403);
    assert.equal(checks.over, 409);
    assert.equal(checks.error.error_code, 'lottery_limit');
    assert(checks.error.errors[0].includes('20 注'));
    assert.equal(checks.state.current.mine, 3);
    assert.equal(checks.after.balance, checks.state.balance);
    assert.equal(checks.state.current.pool, '5012');
    await page.locator('#rl-number').fill('9999');
    await page.locator('#rl-quantity').fill('18');
    assert(await page.locator('.rl-submit').isDisabled());
    await page.locator('#rl-quantity').fill('17');
    await page.locator('.rl-submit').click();
    await page.locator('.rl-success').waitFor();
    await page.waitForFunction(() => document.querySelector('.rl-notice')?.textContent.includes('已购满'));
    assert(await page.locator('.rl-submit').isDisabled());
    await page.setViewportSize({ width: 1360, height: 1100 });
    await page.locator('.rl-page').screenshot({ path: `${process.env.RSC_BROWSER_OUTPUT}/lottery-purchased.png` });
    await context.clearCookies();
    await login(c.admin);
    await page.goto('http://rsc.test:3000/rsc/lottery');
    await page.locator('.rl-accounting summary').click();
    assert.equal(await page.locator('.rl-stats > div').count(), 7);
    assert((await page.locator('.rl-stats').innerText()).includes('-4,980'));
    await page.locator('.rl-page').screenshot({ path: `${process.env.RSC_BROWSER_OUTPUT}/lottery-admin.png` });
    assert.deepEqual(errors, []);
    console.log('PASS banner above six games; desktop/mobile; leading zeros; actual purchase; lost-response replay across reload; CSRF; 20-entry cap; Chinese failures; private admin accounting');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });
