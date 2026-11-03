// Run only against the isolated seeded forum, never production accounts.
const assert=require('node:assert/strict');
const fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const credentials=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const ids=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_IDS));
 const output=process.env.RSC_BROWSER_OUTPUT;fs.mkdirSync(output,{recursive:true});
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1','--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000']});
 try {
  const context=await browser.newContext({viewport:{width:1440,height:1000},locale:'zh-CN'});
  const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto('http://rsc.test:3000/');await page.locator('#main-outlet').waitFor();
  await page.evaluate(async c=>{const csrf=await(await fetch('/session/csrf.json')).json();const response=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf.csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});const body=await response.json();if(!response.ok||body.error)throw Error('Test login failed');},credentials);
  await page.goto('http://rsc.test:3000/rsc/market');
  const position=page.locator('.rsc-position').filter({hasText:'DEMO-A'});await position.waitFor();
  await position.locator('summary').click();
  const form=position.locator('form.rsc-protection').first();
  await form.locator('input').nth(0).fill('100');
  assert(await form.locator('button').isDisabled());
  await position.getByText(/止盈价须大于保本价/).waitFor();
  await form.locator('input').nth(0).fill('150');await form.locator('input').nth(1).fill('120');
  assert(!(await form.locator('button').isDisabled()));
  const saved=page.waitForResponse(r=>r.url().includes('/protection.json')&&r.request().method()==='POST');
  await form.locator('button').click();const response=await saved;
  assert.equal(response.status(),200);const body=await response.json();
  assert(body.protection_saved);assert(body.protection_waiting_quote);assert(!body.waiting_quote);
  await page.getByRole('status').filter({hasText:'止盈止损已保存'}).waitFor();
  assert(!(await page.locator('.rsc-app').innerText()).includes('平仓委托已提交'));
  await page.screenshot({path:`${output}/protection-desktop.png`,fullPage:true});
  await page.setViewportSize({width:390,height:844});
  await form.scrollIntoViewIfNeeded();
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth+1));
  await page.screenshot({path:`${output}/protection-mobile.png`,fullPage:true});
  await form.locator('input').nth(0).fill('');await form.locator('input').nth(1).fill('');
  const cleared=page.waitForResponse(r=>r.url().includes('/protection.json')&&r.request().method()==='POST');
  await form.locator('button').click();assert.equal((await cleared).status(),200);
  for(const [kind,pattern] of [['pending',/此品种已有待成交委托/],['closed',/当前休市，暂不能提交新委托/]]) {
   await page.goto(`http://rsc.test:3000/rsc/market?instrument_id=${ids[kind]}`);
   await page.locator('.rsc-open-order').click();
   const ticket=page.locator('.rsc-order-ticket');await ticket.getByText(pattern).waitFor();
   assert(await ticket.locator('button[type=submit]').isDisabled());
  }
  assert.deepEqual(errors,[]);
  console.log('PASS compiled desktop/mobile UI: exact protection feedback, quote-free save/clear, no false close notice, pending/closed order guards, no overflow or JS errors');
 } finally {await browser.close();}
})().catch(error=>{console.error(error);process.exit(1);});
