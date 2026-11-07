// Runs only against the disposable forum used by run-browser-isolated.sh.
const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--use-angle=swiftshader','--enable-unsafe-swiftshader','--ignore-gpu-blocklist','--in-process-gpu','--host-resolver-rules=MAP rsc.test 127.0.0.1','--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000']});
 try{
  for(const scheme of ['light','dark']){
   const context=await browser.newContext({viewport:{width:1440,height:1100},locale:'zh-CN',colorScheme:scheme});const page=await context.newPage(),errors=[];
   page.on('pageerror',e=>errors.push(e.message));
   await page.goto('http://rsc.test:3000/login',{waitUntil:'networkidle'});
   assert.equal(await page.evaluate(async c=>{
    for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}
   },c),200);
   await page.goto('http://rsc.test:3000/rsc/games');await page.locator('.rg-game-card').first().waitFor();
   assert.equal(await page.locator('.rg-game-card').count(),6);
   for(const width of [1440,390,320]){await page.setViewportSize({width,height:1100});await page.locator('.rg-app').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/lobby-${scheme}-${width}.png`});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'Lobby must fit screen');}
   const widths=scheme==='light'?[1440,390,320]:[1440,390];
   for(const width of widths){
    await page.setViewportSize({width,height:1100});
    for(const [i,name] of ['slots','roulette','scratch','blackjack','coin','dice'].entries()){
     if(await page.locator('.rg-game-card').count()){await page.locator('.rg-game-card').nth(i).click();}else{await page.locator('.rg-tabs button').nth(i).click();}
     await page.locator(`.rg-stage--${name}`).waitFor();
     if(width===1440&&scheme==='light'){
      if(name==='roulette')await page.locator('.rg-outside').getByRole('button',{name:'红',exact:true}).click();
      const response=page.waitForResponse(r=>r.url().includes('/rsc/games/play.json')&&r.request().method()==='POST');await page.locator('.rg-play').click();const res=await response;assert.equal(res.status(),200,await res.text());let round=await res.json();
      assert(!JSON.stringify(round).includes('"deck"'),'Deck never sent to browser');
      if(name==='blackjack'&&round.status==='playing'){
       assert.equal(round.state.dealer[1],null);
       await page.reload();await page.locator('.rg-resume').click();await page.getByRole('button',{name:'停牌',exact:true}).waitFor();
       const action=page.waitForResponse(r=>r.url().includes(`/games/${round.id}/action.json`));await page.getByRole('button',{name:'停牌',exact:true}).click();const ar=await action;assert.equal(ar.status(),200,await ar.text());round=await ar.json();
      }
      if(name==='scratch')await page.getByRole('button',{name:'全部刮开',exact:true}).click();
      await page.locator(name==='scratch'?'.rg-ticket-totals':'.rg-result').waitFor();assert.equal(round.status,'settled');
     }
     await page.locator('.rg-app').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/${name}-${scheme}-${width}.png`});
     assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`${name} fits ${width}`);
     await page.getByRole('button',{name:'玩法与赔率',exact:true}).click();assert(await page.locator('.rg-rules').isVisible());await page.getByRole('button',{name:'玩法与赔率',exact:true}).click();
    }
   }
   if(scheme==='light'){
    const checks=await page.evaluate(async()=>{
     const {csrf}=await(await fetch('/session/csrf.json')).json();
     const body={game:'coin',stake:'1',choice:'heads',request_id:crypto.randomUUID(),payout:'99999',actor_user_id:-1};
     const send=token=>fetch('/rsc/games/play.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':token},body:JSON.stringify(body)});
     const rejected=await send('invalid');const first=await send(csrf),a=await first.json();const replay=await send(csrf),b=await replay.json();
     return {csrf:rejected.status,status:first.status,a,b};
    });
    assert.equal(checks.csrf,403);assert.equal(checks.status,200);assert.equal(checks.a.id,checks.b.id);assert(checks.b.replayed);assert(Number(checks.a.payout)<=2);assert.equal(checks.a.balance,checks.b.balance);
   }
   assert.deepEqual(errors,[]);console.log(`${scheme}: six games, responsive layouts, rules, no browser exceptions`);await context.close();
  }
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
