const assert=require('node:assert/strict'),fs=require('fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{const c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));const browser=await chromium.launch({headless:true,args:['--no-sandbox',`--host-resolver-rules=MAP localhost ${process.env.RSC_BROWSER_IP}`,'--unsafely-treat-insecure-origin-as-secure=http://localhost:3000']});try{
 const page=await browser.newPage({viewport:{width:1360,height:1000}});const errors=[];page.on('pageerror',e=>{errors.push(e.message);console.error(e.message);});
 await page.goto('http://localhost:3000/login');
 assert.equal(await page.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1){const body=await r.json();if(!body.user)throw Error(JSON.stringify({error:body.error,errors:body.errors,reason:body.reason,keys:Object.keys(body)}));return r.status;}}},c),200);
 await page.goto('http://localhost:3000/rsc/lottery');await page.locator('.rl-auto').waitFor({timeout:15000});
 for(const [number,quantity] of [['0012','2'],['3456','3']]){await page.getByRole('button',{name:'＋ 添加号码'}).click();const row=page.locator('.rl-auto-row').last();await row.locator('.rl-auto-number input').fill(number);await row.locator('.rl-auto-quantity input').fill(quantity);}
 assert((await page.locator('.rl-auto-total').innerText()).includes('25'));
 for(const width of [1360,390,320]){await page.setViewportSize({width,height:1000});await page.locator('.rl-auto-heading h2').click();assert(await page.locator('.rl-auto-number input').first().evaluate(el=>el.clientWidth>=90),'number must fit all four digits');await page.locator('.rl-auto').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/auto-${width}.png`});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`overflow ${width}`);}
 await page.locator('.rl-auto-save').click();await page.locator('.rl-auto .rl-success').waitFor();
 let state=await page.evaluate(()=>fetch('/rsc/lottery/state.json').then(r=>r.json()));assert.equal(state.auto_plan.selections.length,2);assert.equal(state.current.mine,0);assert.equal(state.auto_plan.selections[0].number,'0012');assert.equal(state.auto_plan.version,1);
 await page.reload();await page.locator('.rl-auto-row').first().waitFor();assert.equal(await page.locator('.rl-auto-row').count(),2);
 await page.locator('.rl-auto-row').last().locator('input[type=checkbox]').uncheck();await page.locator('.rl-auto-save').click();await page.locator('.rl-auto .rl-success').waitFor();
 state=await page.evaluate(()=>fetch('/rsc/lottery/state.json').then(r=>r.json()));assert.equal(state.auto_plan.selections[1].enabled,false);assert.equal(state.auto_plan.version,2);assert.equal(state.current.mine,0);
 await page.locator('.rl-auto-row').first().locator('.rl-auto-number input').fill('3456');assert(await page.locator('.rl-auto-save').isDisabled());assert((await page.locator('.rl-auto .rl-error').innerText()).includes('合并'));
 await page.getByRole('button',{name:'取消修改'}).click();assert.equal(await page.locator('.rl-auto-row').first().locator('.rl-auto-number input').inputValue(),'0012');
 // Concurrent stale editor cannot overwrite the saved plan.
 assert.equal(await page.evaluate(async()=>{const {csrf}=await(await fetch('/session/csrf.json')).json();return(await fetch('/rsc/lottery/auto-plan.json',{method:'PUT',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify({version:1,selections:[]})})).status;}),409);
 // An authenticated write without a CSRF token must never change the plan.
 const csrfStatus=await page.evaluate(async()=> (await fetch('/rsc/lottery/auto-plan.json',{method:'PUT',headers:{'Content-Type':'application/json'},body:JSON.stringify({version:2,selections:[]})})).status);assert([403,422].includes(csrfStatus));
 assert.deepEqual(errors,[]);console.log('PASS multiple numbers, price, mobile layouts, persistence, toggles, duplicate validation, stale editor and CSRF');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
