const assert=require('node:assert/strict');
const fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const output=process.env.RSC_BROWSER_OUTPUT;fs.mkdirSync(output,{recursive:true});
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1','--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000']});
 try{
  for(const scheme of ['light','dark']){
   const context=await browser.newContext({viewport:{width:1440,height:1000},locale:'zh-CN',colorScheme:scheme});
   if(process.env.RSC_BROWSER_THEME){await context.addInitScript(css=>document.addEventListener('DOMContentLoaded',()=>{const style=document.createElement('style');style.textContent=css;document.head.appendChild(style);}),fs.readFileSync(process.env.RSC_BROWSER_THEME,'utf8'));}
   const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
   await page.goto('http://rsc.test:3000/');await page.locator('#main-outlet').waitFor();
   await page.evaluate(async c=>{const csrf=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf.csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(!r.ok)throw Error('login '+r.status);},c);
   await page.goto('http://rsc.test:3000/rsc/market');await page.locator('.rsc-position').first().waitFor();
   assert.equal(await page.locator('.rsc-heading').count(),0);
   assert.equal(await page.locator('.rsc-trading-summary > div').count(),4);
   assert((await page.locator('#rsc-positions').boundingBox()).y<(await page.locator('.rsc-market-board').boundingBox()).y);
   assert.equal(await page.locator('.rsc-position-details[open]').count(),0);
   // Type one character at a time. Track the actual DOM node through re-renders.
   const position=page.locator('.rsc-position').filter({hasText:'DEMO-A'});
   await position.locator('summary').click();
   for(const [selector,value] of [['.rsc-partial-close input','1.234'],['.rsc-protection input','160.123']]){
    const input=position.locator(selector).first();await input.fill('');
    await input.evaluate(el=>window.workspaceInput=el);
    await input.pressSequentially(value,{delay:120});
    assert.equal(await input.inputValue(),value);
    assert(await page.evaluate(()=>document.activeElement===window.workspaceInput&&window.workspaceInput.isConnected));
    await page.keyboard.press('Backspace');await page.keyboard.press('Backspace');
    assert.equal(await input.inputValue(),value.slice(0,-2));
   }
   const margin=position.locator('form').last().locator('input');await margin.fill('');await margin.pressSequentially('2.25',{delay:100});
   await margin.evaluate(el=>window.workspaceInput=el);
   // Wait for the real automatic state refresh while the draft is focused.
   await page.waitForResponse(r=>r.url().includes('/rsc/state.json')&&r.status()===200,{timeout:20000});
   await page.waitForTimeout(200);
   assert.equal(await margin.inputValue(),'2.25');
   assert(await page.evaluate(()=>document.activeElement===window.workspaceInput&&window.workspaceInput.isConnected));
   if(scheme==='light'){
    await margin.locator('xpath=ancestor::form').getByRole('button').click();
    await page.waitForResponse(r=>r.url().includes('/rsc/state.json')&&r.status()===200);
   }
   await position.locator('summary').click();
   // Selecting a holding opens the quote panel, no navigation away.
   await position.locator('.rsc-position-link').click();await page.locator('.rsc-detail-heading').getByText('河畔科技',{exact:true}).waitFor();
   await page.locator('.rsc-interactive-chart').waitFor();
   const chart=page.locator('.rsc-interactive-chart');
   await chart.scrollIntoViewIfNeeded();
   const readout=page.locator('.rsc-chart-readout');
   const initial=await readout.boundingBox();const initialAxis=await page.locator('.rsc-chart-axis').boundingBox();
   for(const ratio of [.05,.25,.6,.95]){
    const box=await chart.boundingBox();await page.mouse.move(box.x+box.width*ratio,box.y+box.height/2);
    const after=await readout.boundingBox();const axis=await page.locator('.rsc-chart-axis').boundingBox();
    assert(Math.abs(initial.height-after.height)<1,'readout height stable');
    assert(Math.abs(initialAxis.y-axis.y)<1,'axis does not jump on hover');
   }
   assert.match(await page.locator('.rsc-quote-stats').innerText(),/开盘/);
   // Desktop sidebar sticks to the viewport while the market list scrolls.
   await page.evaluate(()=>window.scrollTo(0,650));await page.waitForTimeout(150);
   const side1=await page.locator('.rsc-market-layout').boundingBox();
   await page.evaluate(()=>window.scrollBy(0,200));await page.waitForTimeout(150);
   const side2=await page.locator('.rsc-market-layout').boundingBox();
   assert(Math.abs(side1.y-side2.y)<2,`sticky sidebar moved: ${side1.y} -> ${side2.y}`);
   // Real market pagination, including validity and filter reset.
   const jump=page.locator('.rsc-market-board .rsc-page-jump');
   await jump.getByLabel('目标页码').fill('2');await jump.getByRole('button',{name:'跳转'}).click();
   assert.match(await page.locator('.rsc-market-board .rsc-pagination').innerText(),/2 \/ 3/);
   await jump.getByLabel('目标页码').fill('999');await jump.getByRole('button',{name:'跳转'}).click();
   assert.match(await page.locator('.rsc-market-board .rsc-pagination').innerText(),/2 \/ 3/);
   await page.locator('.rsc-market-board input[type=search]').fill('DEMO-C');
   await page.locator('.rsc-quote-row').first().click();
   assert.equal(await page.locator('.rsc-order-ticket').count(),0);await page.locator('.rsc-open-order').click();
   assert.equal(await page.locator('.rsc-quote-stats dt').count(),2);
   assert.match(await page.locator('.rsc-quote-stats').innerText(),/24h 最高/);
   assert(!/昨收|前收|今开/.test(await page.locator('.rsc-change-basis').innerText()));
   const ticket=page.locator('.rsc-order-ticket');
   assert.match(await ticket.locator('.rsc-risk-status').innerText(),/占用中：DEMO-C/);
   const countdown=await ticket.locator('.rsc-risk-status b').innerText();await page.waitForTimeout(1200);
   assert.notEqual(await ticket.locator('.rsc-risk-status b').innerText(),countdown);
   await ticket.getByLabel('杠杆滑块',{exact:true}).fill('5');
   assert.equal(await ticket.getByLabel('杠杆倍数',{exact:true}).inputValue(),'5');
   const quantity=ticket.locator('.rsc-ticket-inputs input[inputmode=decimal]');
   const values=[];
   for(const name of ['1/4','1/2','3/4','全仓']){
    await quantity.fill('');await ticket.getByRole('button',{name,exact:true}).click();values.push(Number(await quantity.inputValue()));
   }
   assert(values.every((v,i)=>v>0&&(i===0||v>values[i-1])),'allocation increases by fractions');
   await ticket.getByLabel('杠杆倍数',{exact:true}).fill('10');
   assert.equal(await ticket.getByLabel('杠杆滑块',{exact:true}).inputValue(),'10');
   await page.locator('.rsc-market-board input[type=search]').fill('DEMO-OTHER-COIN');await page.locator('.rsc-quote-row').first().click();
   assert.equal(await page.locator('.rsc-order-ticket').count(),0);await page.locator('.rsc-open-order').click();
   await ticket.locator('input[type=checkbox]').check();await ticket.getByLabel('杠杆倍数',{exact:true}).fill('100');
   assert(await ticket.locator('button[type=submit]').isDisabled(),'other high-risk instrument blocked');
   // Return to the stock for viewport checks and screenshots.
   await page.locator('.rsc-market-board input[type=search]').fill('');
   await position.locator('.rsc-position-link').click();
   assert(await page.locator('.rsc-market-layout').evaluate(n=>n.scrollTop===0),'selected quote begins at top');
   for(const width of [1440,1100,1024,768,390,320]){
    await page.setViewportSize({width,height:1000});
    if(width<1100){await page.locator('.rsc-back').click();await position.locator('.rsc-position-link').click();}
    await page.evaluate(()=>window.scrollTo(0,0));
    assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`overflow ${width}`);
    if(!(await page.locator('.rsc-order-ticket').count()))await page.locator('.rsc-open-order').click();
    await page.locator('.rsc-order-ticket').scrollIntoViewIfNeeded();
    assert(await page.locator('.rsc-order-ticket button[type=submit]').count());
    if(width===1440||width===390){await page.evaluate(()=>window.scrollTo(0,0));await page.screenshot({path:`${output}/workspace-${scheme}-${width}.png`,fullPage:true});}
   }
   await page.setViewportSize({width:1440,height:1000});
   await page.goto('http://rsc.test:3000/rsc/leaderboard');
   const rankingJump=page.locator('.rsc-ranking-page > section').first().locator('.rsc-page-jump');
   await rankingJump.getByLabel('目标页码').fill('2');
   await Promise.all([page.waitForResponse(r=>r.url().includes('/rsc/ranking.json')&&r.url().includes('page=2')&&r.status()===200),rankingJump.getByRole('button',{name:'跳转'}).click()]);
   await page.waitForFunction(()=>document.querySelector('.rsc-ranking-page .rsc-pagination')?.textContent.includes('2 / 3'));
   await page.getByLabel('按用户名查找').fill('rsc_alice');
   await Promise.all([page.waitForResponse(r=>r.url().includes('/rsc/ranking.json')&&r.url().includes('q=rsc_alice')),page.getByRole('button',{name:'查询',exact:true}).click()]);
   await page.waitForFunction(()=>document.querySelectorAll('.rsc-trader-link').length===1);
   assert.equal(await page.locator('.rsc-ranking-page .rsc-page-jump').count(),0);
   assert.deepEqual(errors,[]);console.log('PASS',scheme,'draft focus + refresh, positions first, sticky sidebar, stable chart, fractions, slider, pagination, cooldown, six widths');
   await context.close();
  }
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
