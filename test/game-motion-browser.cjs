// Presentation regression test against an isolated forum only; fixed server responses
// let us verify consecutive identical outcomes and all coin/dice orientations.
// Runs twice: with WebGL (three.js scenes) and with WebGL 2 hidden (CSS fallback).
const assert=require('node:assert/strict'),fs=require('node:fs'),crypto=require('node:crypto');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
const out=process.env.RSC_BROWSER_OUTPUT;
const hash=b=>crypto.createHash('sha1').update(b).digest('hex');
(async()=>{
 const c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--use-angle=swiftshader','--enable-unsafe-swiftshader','--ignore-gpu-blocklist','--in-process-gpu','--host-resolver-rules=MAP rsc.test 127.0.0.1','--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000']});
 try{
  for(const mode of ['3d','css']){
  const context=await browser.newContext({viewport:{width:1440,height:1050},locale:'zh-CN'}),page=await context.newPage(),errors=[],threeRequests=[];
  if(mode==='css')await context.addInitScript(()=>{const get=HTMLCanvasElement.prototype.getContext;HTMLCanvasElement.prototype.getContext=function(type,...rest){return type==='webgl2'?null:get.call(this,type,...rest);};});
  page.on('pageerror',e=>errors.push(e.message));
  context.on('request',r=>{if(r.url().includes('rsc-three-'))threeRequests.push(r.url());});
  await page.goto('http://rsc.test:3000/login',{waitUntil:'networkidle'});
  assert.equal(await page.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  await page.goto('http://rsc.test:3000/rsc/games');await page.locator('.rg-game-card').first().waitFor();
  let id=90000+(mode==='css'?5000:0),coin=0;const results={roulette:{number:18},slots:{symbols:['cherry','bell','seven']},dice:{dice:[2,4,6],total:12}};
  await page.route('**/rsc/games/play.json',async route=>{
   const body=route.request().postDataJSON();
   if(body.game==='blackjack')return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({id:++id,game:'blackjack',name:'blackjack',status:'playing',version:1,stake:'10',payout:null,net:null,balance:'990',state:{player:[12,9],dealer:[30,null],player_score:20,dealer_score:5,can_double:true},created_at:new Date().toISOString()})});
   if(body.game==='scratch'){const spots=Array.from({length:10},(_,i)=>i===3?{payout:'5',multiplier:5}:i===7?{payout:'2',multiplier:2}:{payout:'0',multiplier:0});return route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({id:++id,game:'scratch',name:'scratch',status:'settled',version:1,stake:'10',payout:'7',net:'-3',balance:'997',state:{rules_version:2,spot_stake:'1',spots,result:'lose'},created_at:new Date().toISOString()})});}
   const state=body.game==='coin'?{landed:coin++%2?'heads':'tails'}:results[body.game];
   await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({id:++id,game:body.game,name:body.game,status:'settled',version:1,stake:'10',payout:'20',net:'10',balance:'1000',state:{...state,result:'win'},created_at:new Date().toISOString()})});
  });
  await page.route('**/rsc/games/*/action.json',route=>route.fulfill({status:200,contentType:'application/json',body:JSON.stringify({id,game:'blackjack',name:'blackjack',status:'settled',version:2,stake:'10',payout:'20',net:'10',balance:'1010',state:{player:[12,9],dealer:[30,47,15],player_score:20,dealer_score:17,can_double:false,result:'win'},created_at:new Date().toISOString()})}));
  for(const [game,index,selector] of [['roulette',1,'.rg-wheel-disc'],['slots',0,'.rg-reel-strip'],['dice',5,'.rg-die-cube'],['coin',4,'.rg-coin-flipper']]){
   if(await page.locator('.rg-game-card').count())await page.locator('.rg-game-card').nth(index).click();else {await page.getByRole('button',{name:'返回游戏',exact:true}).click();await page.locator('.rg-game-card').nth(index).click();}
   if(mode==='3d'){await page.locator('.rg-stage.is-3d .rg-3d canvas').waitFor({timeout:45000});}
   else{await page.waitForTimeout(300);assert.equal(await page.locator('.rg-stage.is-3d').count(),0,'no WebGL 2 keeps the CSS stage');}
   if(game==='roulette')await page.locator('.rg-outside').getByRole('button',{name:'红',exact:true}).click();
   for(let attempt=0;attempt<2;attempt++){
    await page.locator('.rg-play').click();await page.waitForFunction(()=>document.querySelector('.rg-play')?.textContent.includes('开奖中'));
    assert(await page.locator('.rg-play').isDisabled());assert.equal(await page.locator('.rg-result').count(),0);
    if(mode==='3d'){
     await page.locator('.rg-3d[data-motion="running"]').waitFor();
     const canvas=page.locator('.rg-3d canvas');
     const a=hash(await canvas.screenshot({animations:'allow'}));await page.waitForTimeout(250);const b=hash(await canvas.screenshot({animations:'allow'}));
     assert.notEqual(a,b,`${game} 3D scene moves on round ${attempt+1}`);
    }else{
     const a=await page.locator(selector).first().evaluate(e=>getComputedStyle(e).transform);
     await page.waitForTimeout(250);
     const b=await page.locator(selector).first().evaluate(e=>getComputedStyle(e).transform);assert.notEqual(a,b,`${game} moves on round ${attempt+1}`);
     assert(await page.locator('.rg-stage').evaluate(e=>e.getAnimations({subtree:true}).length>0));
    }
    if(!attempt)await page.locator('.rg-stage').screenshot({path:`${out}/${game}-${mode}-moving.png`,animations:'allow'});
    await page.locator('.rg-result').waitFor({timeout:45000});assert(!(await page.locator('.rg-play').isDisabled()));
    assert.equal(await page.locator('.rg-3d[data-motion]').count(),0);
    assert.equal(await page.locator('.rg-stage').evaluate(e=>e.getAnimations({subtree:true}).filter(a=>!a.effect?.target?.closest?.('.rg-result,.rg-3d-badge')&&a.effect?.getTiming().iterations!==Infinity).length),0);
    if(game==='roulette')assert.equal(await page.locator('.rg-wheel-center>span').textContent(),'18');
    if(game==='slots')assert.deepEqual(await page.locator('.rg-reel-strip').allTextContents(),['🍒','🔔','7']);
    if(game==='dice')assert.deepEqual(await page.locator('.rg-die-space').evaluateAll(es=>es.map(e=>e.getAttribute('aria-label'))),['2 点','4 点','6 点']);
    if(mode==='3d'){
     const label=await page.locator('.rg-3d').getAttribute('aria-label');
     const expected={roulette:'开奖号码 18',slots:'樱桃、铃铛、7',dice:'2、4、6 点，合计 12 点',coin:attempt?'正面（银杏）':'反面（纸船）'}[game];
     assert.equal(label,expected);
     if(game==='roulette')assert.equal(await page.locator('.rg-3d-badge').innerText(),'18');
    }
    await page.locator('.rg-stage').screenshot({path:`${out}/${game}-${mode}-settled-${attempt+1}.png`});
   }
   await page.setViewportSize({width:390,height:1000});await page.waitForTimeout(300);await page.locator('.rg-app').screenshot({path:`${out}/${game}-${mode}-mobile.png`});
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.setViewportSize({width:1440,height:1050});
  }
  if(mode==='3d'){
   // Blackjack: cards are dealt on the WebGL table, controls wait for the deal, hole card turns on stand.
   await page.getByRole('button',{name:'返回游戏',exact:true}).click();await page.locator('.rg-game-card').nth(3).click();await page.locator('.rg-stage.is-3d .rg-3d--blackjack canvas').waitFor({timeout:15000});
   await page.locator('.rg-play').click();await page.locator('.rg-3d--blackjack[data-motion="running"]').waitFor();
   assert(await page.getByRole('button',{name:'停牌',exact:true}).isDisabled(),'actions wait for the deal');
   await page.locator('.rg-stage').screenshot({path:`${out}/blackjack-3d-dealing.png`,animations:'allow'});
   await page.getByRole('button',{name:'停牌',exact:true}).click({timeout:45000});
   await page.locator('.rg-3d--blackjack[data-motion="running"]').waitFor();assert.equal(await page.locator('.rg-result').count(),0);
   await page.locator('.rg-result').waitFor({timeout:45000});
   assert.equal(await page.locator('.rg-3d--blackjack').getAttribute('aria-label'),'庄家 17 点，你的手牌 20 点');
   await page.locator('.rg-stage').screenshot({path:`${out}/blackjack-3d-settled.png`});
   // Scratch: a WebGL ticket flies in; dragging over a spot opens it; reveal-all finishes the rest.
   await page.getByRole('button',{name:'返回游戏',exact:true}).click();await page.locator('.rg-game-card').nth(2).click();await page.locator('.rg-large-ticket.is-3d .rg-3d--scratch canvas').waitFor({timeout:15000});
   await page.locator('.rg-play').click();await page.getByText('已刮开 0 / 10').waitFor();await page.waitForTimeout(900);
   const box=await page.locator('.rg-3d--scratch').boundingBox();
   const y0=box.y+box.height*0.305;await page.mouse.move(box.x+box.width*0.12,y0);await page.mouse.down();
   for(let i=0;i<18;i++)await page.mouse.move(box.x+box.width*(i%2?0.45:0.1),y0+(i%6)*box.height*0.008);
   await page.mouse.up();await page.getByText('已刮开 1 / 10').waitFor({timeout:20000});
   await page.locator('.rg-stage').screenshot({path:`${out}/scratch-3d-scratched.png`});
   await page.getByRole('button',{name:'全部刮开',exact:true}).click();await page.getByText('总返还').waitFor();await page.waitForTimeout(4000);
   await page.locator('.rg-stage').screenshot({path:`${out}/scratch-3d-revealed.png`});
   await page.setViewportSize({width:390,height:1000});await page.waitForTimeout(300);await page.locator('.rg-app').screenshot({path:`${out}/scratch-3d-mobile.png`});
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.setViewportSize({width:1440,height:1050});
  }
  if(mode==='3d'){assert(threeRequests.length>=1,'three.js requested');assert(threeRequests.every(u=>new URL(u).pathname==='/plugins/discourse-rsc/javascripts/rsc-three-0.186.1-b2.js'));}
  else assert.equal(threeRequests.length,0,'no WebGL 2 skips the download');
  for(let i=0;i<6;i++){
   await page.getByRole('button',{name:'返回游戏',exact:true}).click();await page.locator('.rg-game-card').nth(i).click();await page.getByRole('button',{name:'玩法与赔率',exact:true}).click();
   const rules=await page.locator('.rg-rules').innerText();assert(!rules.includes('返还率'));if(i!==3){assert(!rules.includes('二十一点'));assert(!rules.includes('加倍'));}
   if(i===1){assert(!await page.locator('.rg-column-bets').innerText().then(t=>t.includes('…')));assert(rules.includes('1、4、7、10、13、16、19、22、25、28、31、34'));}
  }
  // Reduced motion still animates, about half as long, and then unlocks the controls.
  await page.emulateMedia({reducedMotion:'reduce'});await page.getByRole('button',{name:'返回游戏',exact:true}).click();await page.locator('.rg-game-card').nth(4).click();
  if(mode==='3d')await page.locator('.rg-stage.is-3d').waitFor();
  const reducedStart=Date.now();await page.locator('.rg-play').click();await page.waitForFunction(()=>document.querySelector('.rg-play')?.textContent.includes('开奖中'));
  await page.locator('.rg-result').waitFor({timeout:30000});assert(!(await page.locator('.rg-play').isDisabled()));
  // Route changes during an animation must not leave a timer updating a destroyed component.
  await page.emulateMedia({reducedMotion:'no-preference'});await page.locator('.rg-play').click();await page.waitForFunction(()=>document.querySelector('.rg-play')?.textContent.includes('开奖中'));await page.goto('http://rsc.test:3000/rsc/games');await page.waitForTimeout(2800);
  assert.deepEqual(errors,[]);console.log(`PASS (${mode}): four animations, repeated outcomes, final values, reduced motion, route cleanup, mobile layout and game-specific rules`);
  await context.close();
  }
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
