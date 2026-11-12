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
 for (const width of [1440, 768, 390, 320]) {
   await page.setViewportSize({width,height:1100});
   const metrics=await page.locator('.rsc-position-details').first().evaluate(el=>{
     const forms=[...el.querySelectorAll('form')];
     return forms.map(f=>({form:f.getBoundingClientRect().toJSON(),inputs:[...f.querySelectorAll('input')].map(x=>x.getBoundingClientRect().toJSON()),button:f.querySelector('button').getBoundingClientRect().toJSON()}));
   });
   for (const m of metrics) {
     assert(Math.abs(m.inputs[0].height-44)<1);
     assert(Math.abs(m.button.height-44)<1);
     if(width>600 || m.inputs.length===1) assert(Math.abs(m.inputs[0].y-m.button.y)<1,`misaligned button at ${width}`);
     if(m.inputs.length===2) assert(Math.abs(m.inputs[0].y-m.inputs[1].y)<1);
     assert(Math.abs(m.inputs[0].x-metrics[0].inputs[0].x)<1);
     assert(Math.abs(m.button.right-metrics[0].button.right)<1);
   }
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
   await page.locator('#rsc-positions').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/position-${width}.png`});
 }
 assert.deepEqual(errors,[]);console.log('PASS position form alignment at 1440/768/390/320, equal control heights, no overflow or trade requests');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
