const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS)),base='http://rsc.test:3000';
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--disable-webgl','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});
 const page=await browser.newPage({viewport:{width:390,height:844},hasTouch:true}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(base+'/login',{waitUntil:'networkidle'});
  assert.equal(await page.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  await page.goto(base+'/rsc/games',{waitUntil:'networkidle'});await page.getByRole('button',{name:'博弈区',exact:true}).click();
  for(const name of ['转转乐','幸运转盘','刮刮乐','21点','抛硬币','猜骰子']){
   await page.locator('.rg-game-card').filter({hasText:name}).click();const input=page.locator('#rg-stake');await input.fill('0.01');assert.equal(await input.getAttribute('min'),'0.01');
   if(name!=='幸运转盘'){await input.fill('0.015');assert(await page.locator('.rg-play').isDisabled(),'fraction of a cent rejected');await input.fill('0.01');}
   if(name==='幸运转盘'){
    const red=page.locator('.rg-outside > .rg-spot.red');await red.click();await red.click();assert.equal(await red.locator('small').innerText(),'0.02');
    await page.getByRole('button',{name:'− 减注',exact:true}).click();await red.click();assert.equal(await red.locator('small').innerText(),'0.01');
   }
   assert(await page.locator('.rg-play').isEnabled(),name+' accepts a cent');
   if(name==='抛硬币'){
    const response=page.waitForResponse(r=>r.url().includes('/rsc/games/play.json'));await page.locator('.rg-play').click();const r=await response;assert.equal(r.status(),200);assert.equal((await r.json()).stake,'0.01');
    await page.waitForFunction(()=>!document.querySelector('.rg-stage.is-animating'));await page.screenshot({path:process.env.RSC_BROWSER_OUTPUT+'/cent-coin.png'});
   }
   await page.getByRole('button',{name:'返回游戏',exact:true}).click();
  }
  // A six-cent wallet can cover six one-cent positions, without floating-point overage.
  await page.route('**/rsc/games/state.json*',async route=>{
   const response=await route.fetch({url:route.request().url().replace('rsc.test','127.0.0.1'),headers:{...await route.request().allHeaders(),host:'rsc.test:3000'}});
   const json=await response.json();json.balance='0.06';await route.fulfill({response,json});
  });
  await page.reload({waitUntil:'networkidle'});await page.getByRole('button',{name:'博弈区',exact:true}).click();
  await page.locator('.rg-game-card').filter({hasText:'幸运转盘'}).click();await page.locator('#rg-stake').fill('0.01');
  for(let i=1;i<=6;i++)await page.locator('.rg-number-board button').filter({hasText:new RegExp('^'+i+'$')}).click();
  assert(await page.locator('.rg-play').isEnabled());assert((await page.locator('.rg-bet-total').innerText()).includes('0.06'));
  assert.deepEqual(errors,[]);console.log('PASS six minimum stakes, cent roulette add/subtract and real cent settlement');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1)});
