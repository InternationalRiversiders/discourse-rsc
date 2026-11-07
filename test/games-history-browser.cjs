const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--disable-webgl','--host-resolver-rules=MAP rsc.test 127.0.0.1','--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000']});
 const page=await browser.newPage({viewport:{width:1360,height:1000},locale:'zh-CN'}),errors=[];page.setDefaultTimeout(20000);page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto('http://rsc.test:3000/login',{waitUntil:'networkidle'});
  assert.equal(await page.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  await page.goto('http://rsc.test:3000/rsc/games',{waitUntil:'domcontentloaded'});
  await page.locator('.rg-game-card').filter({hasText:'抛硬币'}).click();
  await page.getByRole('button',{name:'我的记录',exact:true}).click();
  const rows=page.locator('.rg-history-row'),pager=page.locator('.rg-history-pagination');
  await page.waitForFunction(()=>document.querySelectorAll('.rg-history-row').length===20);
  assert((await pager.innerText()).includes('45 条 · 1 / 3'));
  const row=rows.nth(8);await row.scrollIntoViewIfNeeded();const before=await page.evaluate(()=>scrollY),url=page.url();
  await row.click();await page.locator('.rg-history .rg-record').waitFor();
  assert.equal(await row.getAttribute('aria-expanded'),'true');
  assert(await row.evaluate(el=>el.nextElementSibling.querySelector('.rg-record')!==null),'Details are immediately below clicked row');
  assert(Math.abs((await page.evaluate(()=>scrollY))-before)<3,'Opening does not scroll to top');
  assert.equal(page.url(),url);assert.equal(await page.locator('.rg-brand h1').innerText(),'抛硬币','Does not change selected game');
  await page.locator('.rg-record').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/inline-record.png`});
  await row.click();assert.equal(await page.locator('.rg-record').count(),0);
  const first=await rows.first().getAttribute("aria-controls");
  await pager.getByRole('button',{name:'下一页',exact:true}).click();await page.waitForFunction(()=>document.querySelector('.rg-history-pagination').innerText.includes('2 / 3'));
  assert.equal(await rows.count(),20);assert.notEqual(await rows.first().getAttribute("aria-controls"),first);
  await pager.getByRole('button',{name:'下一页',exact:true}).click();await page.waitForFunction(()=>document.querySelector('.rg-history-pagination').innerText.includes('3 / 3'));
  assert.equal(await rows.count(),5);assert(await pager.getByRole('button',{name:'下一页',exact:true}).isDisabled());
  await pager.getByRole('button',{name:'上一页',exact:true}).click();await page.waitForFunction(()=>document.querySelector('.rg-history-pagination').innerText.includes('2 / 3'));
  await page.getByRole('spinbutton',{name:'记录页码'}).fill('1');await pager.getByRole('button',{name:'跳转',exact:true}).click();await page.waitForFunction(()=>document.querySelector('.rg-history-pagination').innerText.includes('1 / 3'));
  assert.equal(await rows.first().getAttribute("aria-controls"),first);assert(await pager.getByRole('button',{name:'上一页',exact:true}).isDisabled());
  assert.equal(await page.evaluate(async()=>(await fetch('/rsc/games/state.json?page=0')).status),400);
  await page.goto(`http://rsc.test:3000/rsc/games?round_id=${c.record_id}`,{waitUntil:'domcontentloaded'});
  await page.locator('.rg-record').waitFor();assert((await pager.innerText()).includes('3 / 3'));assert.equal(await rows.count(),5);assert.equal(await page.locator('.rg-game-card').count(),0);
  assert.equal(await page.locator(`#rg-record-${c.record_id} .rg-record`).count(),1);
  for(const width of [390,320]){await page.setViewportSize({width,height:1000});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.locator('.rg-history').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/history-${width}.png`});}
  await page.reload({waitUntil:'domcontentloaded'});await page.locator(`#rg-record-${c.record_id} .rg-record`).waitFor();
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS: inline expand/collapse without scroll or navigation, 20/20/5 pages, previous/next/jump, page validation, wallet link to older page, reload, 390/320px layout');
 }catch(e){console.error(e.message,errors);throw e;}finally{await browser.close();}
})().catch(()=>process.exit(1));
