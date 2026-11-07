// Real requests against a disposable forum: total price, independent reveal,
// persisted results, duplicate request safety and responsive large-card layout.
const assert = require('node:assert/strict'), fs = require('node:fs');
const { chromium } = require(process.env.RSC_PLAYWRIGHT);
(async () => {
  const credentials = JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
  const browser = await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--use-angle=swiftshader','--enable-unsafe-swiftshader','--ignore-gpu-blocklist','--host-resolver-rules=MAP rsc.test 127.0.0.1','--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000']});
  try {
    const context = await browser.newContext({viewport:{width:1440,height:1100},locale:'zh-CN'});
    const page = await context.newPage(), errors = [];
    page.on('pageerror', e => errors.push(e.message));
    await page.goto('http://rsc.test:3000/login', {waitUntil:'networkidle'});
    assert.equal(await page.evaluate(async c => {
      for (let i=0;i<2;i++) {
        const {csrf}=await(await fetch('/session/csrf.json')).json();
        const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify({login:c.username,password:c.password})});
        if(r.status!==403||i===1)return r.status;
      }
    }, credentials), 200);
    await page.goto('http://rsc.test:3000/rsc/games');
    await page.locator('.rg-game-card').nth(2).click();
    assert.equal(await page.locator('.rg-ticket-spot').count(),10);
    assert.equal(await page.locator('.rg-ticket-spot-preview').count(),10);
    const records=[];
    for(const price of ['10','20','1.01']) {
      await page.locator('#rg-stake').fill(price);
      if (!records.length) { assert((await page.locator('.rg-ticket-price').innerText()).includes(price)); }
      const before=await page.evaluate(async()=> (await(await fetch('/rsc/games/state.json')).json()).balance);
      const response=page.waitForResponse(r=>r.url().includes('/rsc/games/play.json'));
      await page.locator('.rg-play').click();
      const res=await response;assert.equal(res.status(),200,await res.text());
      const round=await res.json(); records.push(round);
      await page.waitForFunction(price => document.querySelector('.rg-ticket-price')?.textContent.trim() === `${price} RSC`, price);
      assert.equal(round.stake,price);
      assert.equal(round.state.spots.length,10);
      assert.equal(Number(round.state.spot_stake),Number(price)/10);
      assert(Math.abs(Number(round.balance)-(Number(before)-Number(price)+Number(round.payout)))<1e-8);
      assert(Math.abs(Number(round.payout)-round.state.spots.reduce((sum,x)=>sum+Number(x.payout),0))<1e-8);
      assert.equal(await page.locator('.rg-ticket-spot-cover').count(),10);
      assert.equal(await page.locator('.rg-ticket-totals').count(),0);
      if(price==='10') {
        // Scratch one complete spot with real pointer strokes.
        const box=await page.locator('.rg-ticket-spot-cover').first().boundingBox();
        await page.mouse.move(box.x+3,box.y+3);await page.mouse.down();
        for(let y=5;y<box.height;y+=8) {
          await page.mouse.move(box.x+3,box.y+y);
          await page.mouse.move(box.x+box.width-3,box.y+y,{steps:6});
        }
        await page.mouse.up();
        await page.waitForFunction(()=>document.querySelectorAll('.rg-ticket-spot-cover').length===9);
        assert((await page.locator('.rg-large-ticket-footer').innerText()).includes('1 / 10'));
        await page.locator('.rg-large-ticket').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/scratch-partial.png`});
      }
      await page.getByRole('button',{name:'全部刮开',exact:true}).click();
      assert.equal(await page.locator('.rg-ticket-spot-cover').count(),0);
      await page.locator('.rg-ticket-totals').waitFor();
      assert.equal(await page.locator('.rg-result').count(),0,'Only one total summary');
      // Replay exactly the browser's request; it must not buy another card.
      const replay=await page.evaluate(async body=>{
        const {csrf}=await(await fetch('/session/csrf.json')).json();
        return (await fetch('/rsc/games/play.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify(body)})).json();
      },res.request().postDataJSON());
      assert(replay.replayed);assert.equal(replay.id,round.id);assert.equal(replay.balance,round.balance);assert.deepEqual(replay.state.spots,round.state.spots);
    }
    for(const scheme of ['light','dark']) {
      await page.emulateMedia({colorScheme:scheme});
      for(const width of [1440,390,320]) {
        await page.setViewportSize({width,height:1100});
        assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
        await page.locator('.rg-app').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/scratch-${scheme}-${width}.png`});
      }
    }
    await page.reload();await page.locator('.rg-game-card').first().waitFor();
    await page.getByRole('button',{name:'我的记录',exact:true}).click();
    await page.locator('.rg-history-row').first().click();
    await page.locator('.rg-ticket-totals').waitFor();
    assert.equal(await page.locator('.rg-ticket-spot').count(),10);
    const saved=await page.evaluate(async()=> (await(await fetch('/rsc/games/state.json')).json()).history[0]);
    assert.deepEqual(saved.state.spots,records.at(-1).state.spots);
    assert.deepEqual(errors,[]);
    console.log('PASS: ten-spot card, 10/20/fractional total price, manual/all reveal, one debit, retry, history and mobile layouts');
    await context.close();
  } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1);});
