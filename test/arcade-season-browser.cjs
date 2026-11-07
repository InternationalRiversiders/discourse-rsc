const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const base='http://rsc.test:3000',out=process.env.RSC_BROWSER_OUTPUT,c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});
 const page=await browser.newPage({viewport:{width:1360,height:1000},locale:'zh-CN'}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(base+'/login',{waitUntil:'networkidle'});
  assert.equal(await page.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  await page.goto(base+'/rsc/games',{waitUntil:'networkidle'});await page.locator('.ra-season-banner').waitFor();
  assert((await page.locator('.ra-season-banner').innerText()).includes('100 / 60 / 40 / 25 / 15'));
  assert.equal(await page.locator('.ra-intro').count(),0);assert.equal(await page.getByText('玩一局，刷新自己',{exact:true}).count(),0);assert.equal(await page.locator('.ra-featured-tag').count(),1);assert.equal(await page.locator('.ra-card-label p').count(),0,'cards have no subtitles');
  for(const width of [1360,390,320]){await page.setViewportSize({width,height:1000});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await page.locator('.ra-app').screenshot({path:`${out}/season-lobby-${width}.png`});}
  await page.locator('.ra-season-banner').click();await page.getByRole('button',{name:'赛季排行',exact:true}).waitFor();
  assert.equal(await page.locator('.ra-rank-tabs .is-active').innerText(),'赛季排行');
  await page.getByRole('button',{name:'总排行',exact:true}).click();await page.getByLabel('排行说明',{exact:true}).click();assert((await page.locator('.ra-rank-popover').innerText()).includes('历史最高分永久保留'));await page.getByLabel('排行说明',{exact:true}).click();
  await page.getByRole('button',{name:'返回挑战',exact:false}).click();
  await page.locator('.ra-card').filter({hasText:'河畔飞鸟'}).click();await page.waitForTimeout(250);
  assert.equal(await page.getByRole('button',{name:'赛季排行',exact:true}).count(),0);
  // Public, framework-independent bundle: fetch through its real plugin URL.
  const manifest=await page.evaluate(async()=>await(await fetch('/plugins/discourse-rsc/arcade/manifest.json')).json());
  assert.equal(manifest.rules_version,1);await page.addScriptTag({url:base+manifest.script});
  const result=await page.evaluate(()=>{
   const {Core,Effects,draw}=RiversideArcade,canvas=document.createElement('canvas'),q=Array(20).fill(3733);
   const effect=new Effects();let s=Core.create('2048',q);s.board=[2,0,0,0,0,2,0,0,...Array(8).fill(0)];
   const original=JSON.stringify(s);const move={direction:'r',board:s.board.slice()};effect.observe(s,null,0);s=Core.preview(s,'r');effect.observe(s,move,10);
   draw(canvas,s,effect,10);const start=canvas.toDataURL();draw(canvas,s,effect,70);const middle=canvas.toDataURL();draw(canvas,s,effect,500);const end=canvas.toDataURL();
   const animations=start!==middle&&middle!==end;
   for(const game of Core.games){const state=Core.create(game,q),before=JSON.stringify(state),fx=new Effects();fx.observe(state);draw(canvas,state,fx);if(before!==JSON.stringify(state))throw new Error('mutated '+game);}
   return {animations,version:RiversideArcade.rulesVersion};
  });
  const loaded=await page.evaluate(async()=>{
   const images=await RiversideArcade.loadMergeSprites();
   return images.map(i=>!!(i&&i.complete&&i.naturalWidth));
  });assert.equal(loaded.length,11);assert(loaded.every(Boolean),'all original merge artwork loads');
  await page.getByRole('button',{name:'返回挑战',exact:false}).click();await page.locator('.ra-card').filter({hasText:'合成大河畔'}).click();
  await page.waitForTimeout(400);await page.locator('.ra-play').screenshot({path:`${out}/merge-original-artwork.png`});
  assert(result.animations,'2048 actually moves between display frames');assert.equal(result.version,1);
  assert.deepEqual(errors,[]);console.log('PASS responsive season banner, separate lifetime/season ranks, real SDK URL, seven renderers, animated 2048 frames and all eleven original merge sprites');
 }catch(e){await page.screenshot({path:out+'/season-failure.png',fullPage:true}).catch(()=>{});throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
