const assert = require('node:assert/strict');
const fs = require('node:fs');
const { chromium } = require(process.env.RSC_PLAYWRIGHT || 'playwright');
(async () => {
  const browser = await chromium.launch({ executablePath: process.env.RSC_CHROMIUM, args: ['--no-sandbox'] });
  try {
    const page = await browser.newPage();
    // Exercise the real browser timer receiver, not the deterministic clock used
    // by the unit tests. No network or production data is needed.
    await page.addScriptTag({ content: fs.readFileSync(require('node:path').join(__dirname, '../assets/javascripts/discourse/lib/rsc-tip-requests.js'), 'utf8').replace('export default class TipRequests', 'window.TipRequests = class TipRequests') });
    const result = await page.evaluate(async () => {
      let calls = 0;
      const queue = new window.TipRequests({ request: async (_topic, ids) => { calls++; return { posts: Object.fromEntries(ids.map(id => [id, {count: 1}])) }; } });
      const values = await Promise.all(Array.from({length: 105}, (_,i)=>queue.get({id:i+1,topic_id:1})));
      queue.destroy();return {calls, count: values.length, valid: values.every(v=>v.count===1)};
    });
    assert.deepEqual(result,{calls:2,count:105,valid:true});
    console.log('PASS native Chromium timers, batching and teardown');
  } finally { await browser.close(); }
})().catch(e => { console.error(e); process.exitCode = 1; });
