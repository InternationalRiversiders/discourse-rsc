const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{const c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));const browser=await chromium.launch({headless:true,args:['--no-sandbox',`--host-resolver-rules=MAP localhost ${process.env.RSC_BROWSER_IP}`]});try{
 const page=await browser.newPage({viewport:{width:1440,height:1100}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('**/rsc/**',route=>{if(route.request().method()!=='GET')throw Error('UI test must not submit trades');return route.continue();});
 await page.goto('http://localhost:3000/login');
 assert.equal(await page.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1){const body=await r.json();if(!body.user)throw Error(JSON.stringify({error:body.error,errors:body.errors,reason:body.reason,keys:Object.keys(body)}));return r.status;}}},c),200);
 await page.goto('http://localhost:3000/rsc/market');await page.locator('.rsc-position').first().waitFor();
 await page.locator('#rsc-positions').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/close-collapsed.png`});
 await page.locator('.rsc-position-details summary').first().click();
 await page.locator('#rsc-positions').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/close-expanded.png`});
 await page.locator('.rsc-position-details summary').first().click();
 await page.locator('.rsc-quote-row').first().click();await page.locator('.rsc-chart').waitFor();
 const bar=page.getByRole('separator',{name:'调整行情列表和详情宽度'});await bar.waitFor();
 const initial=(await page.locator('.rsc-market-main').boundingBox()).width,box=await bar.boundingBox();
 await page.mouse.move(box.x+10,box.y+80);await page.mouse.down();await page.mouse.move(box.x-80,box.y+80,{steps:10});await page.mouse.up();
 const changed=(await page.locator('.rsc-market-main').boundingBox()).width;assert(changed<initial-50);
 await page.locator('.rsc-workbench').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/split-desktop.png`});
 await page.reload();await page.locator('.rsc-market-board').waitFor();await page.locator('.rsc-quote-row').first().click();await bar.waitFor();assert(Math.abs((await page.locator('.rsc-market-main').boundingBox()).width-changed)<2);
 for(const width of [390,320]){await page.setViewportSize({width,height:1000});assert(!(await bar.isVisible()));assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.locator('.rsc-back').click();await page.locator('#rsc-positions').waitFor();await page.locator('.rsc-quote-row').first().click();await page.locator('.rsc-chart').waitFor();}
 assert.deepEqual(errors,[]);console.log('PASS real forum split, persistence, position controls, mobile detail/back and no trade requests');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
