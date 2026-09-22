const assert = require('node:assert/strict');
const fs = require('node:fs');
const { chromium } = require(process.env.RSC_PLAYWRIGHT);
(async () => {
  const credentials = JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
  const browser = await chromium.launch({ executablePath: process.env.RSC_CHROMIUM, args: ['--no-sandbox', '--host-resolver-rules=MAP rsc.test 127.0.0.1', '--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000'] });
  try {
    for (const colorScheme of ['light', 'dark']) {
      const context = await browser.newContext({ viewport: { width: 1440, height: 1000 }, colorScheme, locale: 'zh-CN' });
      const page = await context.newPage();
      const errors = []; page.on('pageerror', e => errors.push(e.message));
      // The forum and its API are real; only external images are substituted
      // because this disposable container intentionally has no external network.
      await page.route('https://a.espncdn.com/**', route => route.request().url().endsWith('364.png')
        ? route.abort()
        : route.fulfill({ contentType: 'image/svg+xml', body: '<svg xmlns="http://www.w3.org/2000/svg" width="48" height="48"><circle cx="24" cy="24" r="20" fill="#da291c"/></svg>' }));
      await page.goto('http://rsc.test:3000/');
      await page.locator('#main-outlet').waitFor();
      await page.evaluate(async c => {
        const csrf = await (await fetch('/session/csrf.json')).json();
        const r = await fetch('/session.json', {method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf.csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});
        if (!r.ok) throw Error('login '+r.status);
      }, credentials);
      await page.goto('http://rsc.test:3000/rsc/sports');
      const card = page.locator('.rsc-match').filter({hasText:'阿森纳'});
      await card.waitFor();
      await card.scrollIntoViewIfNeeded();
      await page.waitForFunction(() => [...document.querySelectorAll('.rsc-team-logo')].some(img => img.complete && img.naturalWidth > 0));
      await card.locator('.rsc-team-symbol.away').filter({hasText:'利物'}).waitFor();
      assert.equal(await card.locator('.rsc-team-logo').count(), 1, 'failed image replaced by initials');
      assert.equal(await card.locator('.rsc-team-name').first().innerText(), '阿森纳\nArsenal');
      assert.match(await card.innerText(), /A组/);
      assert.match(await page.locator('.rsc-match').filter({hasText:'Unknown FC'}).innerText(), /波士顿凯尔特人/);
      for (const width of [1440, 768, 390, 320]) {
        await page.setViewportSize({width,height:1000});
        assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth + 1), 'page overflow');
        const badge = await card.locator('.rsc-team-logo').boundingBox();
        assert.equal(badge.width, 48); assert.equal(badge.height, 48);
        await page.screenshot({path:process.env.RSC_BROWSER_OUTPUT+'/sports-'+colorScheme+'-'+width+'.png',fullPage:true});
      }
      assert.deepEqual(errors, []);
      console.log(colorScheme+': logos, failure fallback, translations, 4 widths passed');
      await context.close();
    }
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exit(1); });
