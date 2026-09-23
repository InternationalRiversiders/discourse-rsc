// Real browser regression: browsing quotes does not open an order ticket.
const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1','--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000']});
 try{
 for(const scheme of ['light','dark']){
  const context=await browser.newContext({viewport:{width:1920,height:1000},locale:'zh-CN',colorScheme:scheme});
  const page=await context.newPage(),errors=[];let histories=0;
  page.on('pageerror',e=>errors.push(e.message));page.on('request',r=>{if(r.url().includes('/history.json'))histories++;});
  await page.route('**/rsc/orders.json',route=>{if(route.request().method()==='POST')throw Error('Layout test must not trade');return route.continue();});
  await page.goto('http://rsc.test:3000/login');
  assert.equal(await page.evaluate(async c=>{const csrf=await(await fetch('/session/csrf.json')).json();return (await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf.csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})})).status;},c),200);
  for(const width of [3840,2560,1920,1440,1024,390,320]){
   await page.setViewportSize({width,height:1000});histories=0;
   await page.goto('http://rsc.test:3000/latest',{waitUntil:'domcontentloaded'});await page.locator('.topic-list').waitFor();
   const forumFrame=await page.locator('#main-outlet-wrapper').boundingBox();
   await page.goto('http://rsc.test:3000/rsc/market',{waitUntil:'domcontentloaded'});await page.locator('.rsc-market-board').waitFor();
   await page.waitForFunction(()=>getComputedStyle(document.querySelector('.rsc-app')).maxWidth==='1440px');
   const rscFrame=await page.locator('#main-outlet-wrapper').boundingBox();
   assert(Math.abs(rscFrame.x-forumFrame.x)<2 && Math.abs(rscFrame.width-forumFrame.width)<2,'RS Coin must not resize the forum frame');
   assert.equal(await page.locator('.rsc-market-layout,.rsc-order-ticket').count(),0);
   assert.equal(histories,0,'No unselected instrument history requests');
   const app=await page.locator('.rsc-app').boundingBox(),main=await page.locator('.rsc-market-main').boundingBox(),workbench=await page.locator('.rsc-workbench').boundingBox();
   assert(Math.abs(main.width-workbench.width)<2,'List uses the entire workspace before selection');
   if(width===1920)assert(app.width<=1440 && app.width>=1200,'Desktop market has a bounded reading width');
   await page.locator('.rsc-quote-row').first().click();await page.locator('.rsc-chart').waitFor();
   assert.equal(await page.locator('.rsc-order-ticket').count(),0,'Quote-only view');
   await page.locator('.rsc-open-order').click();await page.locator('.rsc-order-ticket').waitFor();
   const quantity=page.locator('.rsc-order-ticket input').first();await quantity.fill('1.25');
   await page.locator('.rsc-close-order').click();assert.equal(await page.locator('.rsc-order-ticket').count(),0);await page.locator('.rsc-chart').waitFor();
   await page.locator('.rsc-open-order').click();assert.equal(await quantity.inputValue(),'1.25','Collapsing preserves the current draft');
   if(width===1920||width===390)await page.screenshot({path:process.env.RSC_BROWSER_OUTPUT+`/market-open-${scheme}-${width}.png`});
   await page.locator('.rsc-back').click();assert.equal(await page.locator('.rsc-market-layout,.rsc-order-ticket').count(),0);
   assert.equal(await page.locator('.rsc-quote-actions').count(),0);
   await page.locator('.rsc-quote-row').first().click();await page.locator('.rsc-open-order').click();await page.locator('.rsc-order-ticket').waitFor();
   await page.locator('.rsc-order-ticket select').first().selectOption('short');
   assert.equal(await page.locator('.rsc-order-ticket select').inputValue(),'short');
   await page.locator('.rsc-market-jumps a').first().click();assert.equal(await page.locator('.rsc-market-layout').count(),0);
   await page.locator('.rsc-position-link').first().click();await page.locator('.rsc-chart').waitFor();assert.equal(await page.locator('.rsc-order-ticket').count(),0);
   await page.locator('.rsc-back').click();
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'No page overflow '+width);
   if(width===1920||width===390){await page.evaluate(()=>scrollTo(0,0));await page.screenshot({path:process.env.RSC_BROWSER_OUTPUT+`/market-list-${scheme}-${width}.png`});}
   console.log('PASS',scheme,width,'wide list, quote-only view, explicit trading, collapse and return, holdings preview');
  }
  const loaded=page.waitForResponse(r=>r.url().includes('/instruments/1/history.json')&&r.status()===200);
  await page.goto('http://rsc.test:3000/rsc/market?instrument_id=1',{waitUntil:'domcontentloaded'});await page.locator('.rsc-chart').waitFor();assert.equal(await page.locator('.rsc-order-ticket').count(),0);
  await loaded;await page.locator('.rsc-back').click();const closedHistories=histories;
  await page.waitForResponse(r=>r.url().includes('/rsc/state.json')&&r.status()===200,{timeout:20000});assert.equal(histories,closedHistories,'Closing the panel stops its history polling');assert.equal(await page.locator('.rsc-market-layout').count(),0);
  await page.goto('http://rsc.test:3000/rsc/market?instrument_id=999999999',{waitUntil:'domcontentloaded'});await page.locator('.rsc-market-board').waitFor();assert.equal(await page.locator('.rsc-market-layout,.rsc-order-ticket').count(),0);
  await page.goto('http://rsc.test:3000/latest',{waitUntil:'domcontentloaded'});await page.locator('#main-outlet').waitFor();
  assert.deepEqual(errors,[]);await context.close();
 }
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1;});
