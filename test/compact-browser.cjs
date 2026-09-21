const assert=require('node:assert/strict');
const fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT || 'playwright');
(async()=>{
 const output=process.env.RSC_BROWSER_OUTPUT || '/tmp/rsc-compact-browser'; fs.mkdirSync(output,{recursive:true});
 const credentials=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS || '/tmp/rsc-browser-key.json'));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1','--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000']});
 try {
 for(const scheme of ['light','dark']) {
  const context=await browser.newContext({viewport:{width:1440,height:1000},colorScheme:scheme,locale:'zh-CN'});
  const page=await context.newPage();page.setDefaultTimeout(30000);const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto('http://rsc.test:3000/login',{waitUntil:'domcontentloaded'});
  await page.evaluate(async c=>{const csrf=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf.csrf},body:JSON.stringify({login:c.username,password:c.password})});if(!r.ok)throw Error('login '+r.status);},credentials);
  const sameRow=async selector=>{const ys=await page.locator(selector).evaluateAll(nodes=>nodes.map(n=>Math.round(n.getBoundingClientRect().y)));assert(ys.length>1&&Math.max(...ys)-Math.min(...ys)<=2,`${selector} wraps: ${ys}`);};
  const noOverflow=async()=>assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'document overflow');
  for(const width of [1440,1024,768,390,320]) {
   await page.setViewportSize({width,height:1000});
   await page.goto('http://rsc.test:3000/rsc',{waitUntil:'domcontentloaded'});
   await page.waitForFunction(()=>document.querySelectorAll('.rsc-wallet-history tbody tr[id]').length===20);
   assert(!await page.locator('.rsc-wallet-history').innerText().then(t=>t.includes('迁移')));
   if(width>700)await sameRow('.rsc-reward-summary .rsc-market-summary > div');
   await noOverflow();
   if(width===1440){
    await page.screenshot({path:`${output}/wallet-${scheme}.png`,fullPage:true});
    await page.getByRole('button',{name:'加载更早记录'}).click();
    await page.waitForFunction(()=>document.querySelectorAll('.rsc-wallet-history tbody tr[id]').length===37);
    assert.equal(await page.locator('.rsc-wallet-history tbody tr[id]').evaluateAll(ns=>new Set(ns.map(n=>n.id)).size),37);
    await Promise.all([page.waitForResponse(r=>r.url().includes('/rsc/history.json')&&r.url().includes('payout')),page.getByLabel('流水分类').selectOption('payout')]);
    await page.getByText('暂无流水',{exact:true}).waitFor();
   }
   await page.goto('http://rsc.test:3000/rsc/market',{waitUntil:'domcontentloaded'});await page.locator('#rsc-orders tbody tr').first().waitFor();
   const pnls=await page.locator('.rsc-order-pnl').allTextContents();assert.deepEqual(pnls.map(x=>x.trim()),['—','0','-12.5','+0.1579']);
   const colors=await page.locator('.rsc-order-pnl strong').evaluateAll(ns=>ns.map(n=>({text:n.textContent.trim(),color:getComputedStyle(n).color})));
   assert.notEqual(colors.find(x=>x.text==='-12.5').color,colors.find(x=>x.text==='+0.1579').color);
   assert(!await page.locator('#rsc-orders').innerText().then(t=>t.includes('迁移前')));
   if(width===1440){
    const heights=await page.locator('#rsc-orders tbody tr').evaluateAll(ns=>ns.map(n=>n.getBoundingClientRect().height));assert(heights.every(h=>h<100),JSON.stringify(heights));
    await page.locator('#rsc-orders').screenshot({path:`${output}/orders-${scheme}.png`});
    await page.locator('#rsc-orders summary').first().click();await page.getByText('名义金额 20.4359 RSC',{exact:true}).first().waitFor();
   }
   await noOverflow();
   await page.goto('http://rsc.test:3000/rsc/sports',{waitUntil:'domcontentloaded'});await page.locator('.rsc-sports-filters select').first().waitFor();
   if(width>700)await sameRow('.rsc-sports-filters select');
   await page.locator('.rsc-sports-filters select').first().selectOption('basketball');
   assert.equal(await page.locator('.rsc-match').count(),1);
   assert((await page.locator('.rsc-match').innerText()).includes('蓝鲸'));
   await noOverflow();
   if(width===1440)await page.locator('.rsc-sports-filters').screenshot({path:`${output}/filters-${scheme}.png`});
   await page.goto('http://rsc.test:3000/rsc/leaderboard',{waitUntil:'domcontentloaded'});await page.locator('.rsc-ranking-search').waitFor();
   if(width>700)await sameRow('.rsc-ranking-search input, .rsc-ranking-search button, .rsc-ranking-search select');
   await page.getByLabel('按用户名查找').fill('rsc_alice');
   await Promise.all([page.waitForResponse(r=>r.url().includes('/rsc/ranking.json')&&r.url().includes('q=rsc_alice')),page.getByRole('button',{name:'查询',exact:true}).click()]);
   await page.locator('.rsc-ranking-page:not([aria-busy="true"])').waitFor();
   await page.waitForFunction(()=>document.querySelectorAll('.rsc-trader-link').length===1);
   assert.equal((await page.locator('.rsc-trader-link').innerText()).trim(),'rsc_alice');
   await Promise.all([page.waitForResponse(r=>r.url().includes('sort=return_pct')),page.getByLabel('排序方式').selectOption('return_pct')]);
   await page.locator('.rsc-ranking-page:not([aria-busy="true"])').waitFor();
   await noOverflow();
   if(width===1440)await page.locator('.rsc-ranking-search').screenshot({path:`${output}/ranking-${scheme}.png`});
   console.log('PASS',scheme,width,'reward/history/orders/filters/ranking');
  }
  if(scheme==='dark'){
   await page.goto('http://rsc.test:3000/rsc',{waitUntil:'domcontentloaded'});await page.locator('.rsc-wallet-history tbody tr[id]').first().waitFor();
   await page.getByLabel('接收人用户名').fill('rsc_bob');await page.getByLabel('金额（RSC）',{exact:true}).fill('1.25');
   await page.getByRole('button',{name:'转账',exact:true}).click();
   await page.waitForFunction(()=>document.querySelector('.rsc-wallet-history tbody tr:first-child td:nth-child(3)')?.textContent.trim()==='-1.25');
   console.log('PASS new transfer refreshes recent history immediately');
  }
  assert.deepEqual(errors,[]);await context.close();
 }
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
