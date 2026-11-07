const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const base=`http://rsc.test:${process.env.RSC_BROWSER_PORT||3000}`;
 const c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--use-angle=swiftshader','--enable-unsafe-swiftshader','--ignore-gpu-blocklist','--in-process-gpu','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});
 const context=await browser.newContext({viewport:{width:1000,height:900},deviceScaleFactor:3,locale:'zh-CN'});
 const page=await context.newPage(),errors=[];page.on('pageerror',e=>errors.push(e.message));
 async function resolution(moving=false){
  const canvas=page.locator('.rg-stage .rg-3d-canvas').first();await canvas.waitFor();
  // ResizeObserver runs after a hidden scene becomes visible; wait for its first sized frame.
  await page.waitForFunction(moving=>{
   const c=document.querySelector('.rg-stage .rg-3d-canvas');if(!c||!c.clientWidth||!c.clientHeight)return false;
   const target=Math.min(moving?2:2.5,Math.sqrt((moving?1250000:2000000)/(c.clientWidth*c.clientHeight)));
   return Math.abs(c.width/c.clientWidth-target)<.02;
  },moving,{timeout:20000});
  const size=await canvas.evaluate(c=>({width:c.width,height:c.height,w:c.clientWidth,h:c.clientHeight}));
  const target=Math.min(moving?2:2.5,Math.sqrt((moving?1250000:2000000)/(size.w*size.h)));
  assert(Math.abs(size.width/size.w-target)<.02,JSON.stringify({size,target}));
  assert(size.width*size.height<=(moving?1250000:2000000)+2000);
  return size;
 }
 try{
  await page.goto(base+'/login',{waitUntil:'networkidle'});
  assert.equal(await page.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  const state=await page.evaluate(async()=>await(await fetch('/rsc/games/state.json')).json());
  await page.route('**/rsc/games/state.json*',r=>r.fulfill({contentType:'application/json',body:JSON.stringify({...state,active:null,selected_round:null})}));
  let id=99000;
  await page.route('**/rsc/games/play.json',r=>r.fulfill({contentType:'application/json',body:JSON.stringify({id:++id,game:'coin',status:'settled',version:1,stake:'10',payout:'0',net:'-10',balance:'1000',state:{choice:'heads',landed:'tails',result:'lose',rules_version:3},created_at:new Date().toISOString()})}));
  await page.goto(base+'/rsc/games',{waitUntil:'domcontentloaded'});
  await page.locator('.rg-game-card').first().click();
  for(const [i,game] of ['slots','roulette','scratch','blackjack','coin','dice'].entries()){
   await page.locator('.rg-tabs button').nth(i).click();
   await page.locator(game==='scratch'?'.rg-large-ticket.is-3d':'.rg-stage.is-3d').waitFor({timeout:30000});
   const size=await resolution();console.log(game,JSON.stringify(size));
   if(game==='blackjack'||game==='slots')await page.locator('.rg-stage').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/${game}-hd.png`});
  }
  await page.locator('.rg-tabs button').nth(4).click();await page.locator('.rg-stage.is-3d').waitFor();await resolution();
  await page.locator('.rg-play').click();await page.locator('.rg-3d[data-motion="running"]').waitFor();await resolution(true);
  await page.locator('.rg-result').waitFor({timeout:45000});await resolution();
  await page.setViewportSize({width:390,height:900});await resolution();
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
  await page.locator('.rg-stage').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/coin-hd-mobile.png`});
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS: six HiDPI scenes, animation pixel budget, restored final resolution, resize and no WebGL/browser errors');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
