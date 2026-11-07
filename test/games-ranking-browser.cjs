const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--disable-webgl','--host-resolver-rules=MAP rsc.test 127.0.0.1','--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000']});
 const page=await browser.newPage({viewport:{width:1360,height:1100},locale:'zh-CN'}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto('http://rsc.test:3000/login',{waitUntil:'networkidle'});
  assert.equal(await page.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  const api=await page.evaluate(async()=>{
   const boards={};for(const game of ['coin','dice','slots','scratch','roulette','blackjack','lottery']){const r=await fetch(`/rsc/games/ranking.json?game=${game}`);boards[game]={status:r.status,data:await r.json()};}
   const invalid=await fetch('/rsc/games/ranking.json?game=coin&period=nope');
   return {boards,invalid:invalid.status};
  });
  for(const [game,{status,data}] of Object.entries(api.boards)){assert.equal(status,200,game);assert.equal(data.metric,['coin','dice','blackjack'].includes(game)?'streak':'net');assert(data.rows.length<=10);for(const r of data.rows){assert.deepEqual(Object.keys(r).sort(),['achieved_at','user','value']);assert(r.user.username);}}
  assert.equal(api.invalid,422);
  await page.goto('http://rsc.test:3000/rsc/games',{waitUntil:'domcontentloaded'});
  await page.locator('.rg-game-card').filter({hasText:'抛硬币'}).click();
  await page.locator('.rg-ranking[aria-busy="false"]').waitFor();
  assert.equal(await page.locator('.rg-ranking h2').innerText(),'连胜榜');
  await page.getByRole('button',{name:'玩法与赔率',exact:true}).click();
  assert((await page.locator('.rg-rules').innerText()).includes('返还 2 倍'));
  await page.locator('.rg-ranking').getByRole('button',{name:'总榜',exact:true}).click();
  await page.locator('.rg-ranking[aria-busy="false"]').waitFor();
  // Long IDs and large scores must fit a phone, using only public identity fields.
  await page.route('**/rsc/games/ranking.json*',r=>r.fulfill({contentType:'application/json',body:JSON.stringify({metric:'net',rows:Array.from({length:10},(_,i)=>({user:{id:i+10,username:'很长的用户名ABCDEFGHIJKLMNOPQRSTUVWXYZ'+i,avatar_template:'/letter_avatar_proxy/v4/letter/a/0088cc/{size}.png'},value:'12500.55',achieved_at:new Date().toISOString()}))})}));
  await page.locator('.rg-tabs').getByRole('button',{name:'转转乐',exact:true}).click();
  await page.locator('.rg-ranking-list li').first().waitFor();
  assert.equal(await page.locator('.rg-ranking h2').innerText(),'单局净盈利榜');
  assert.equal(await page.locator('.rg-ranking-list li').count(),10);
  assert.equal(await page.locator('.rg-ranking-list [data-user-card]').count(),10);
  for(const width of [1360,390,320]){await page.setViewportSize({width,height:1000});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`overflow ${width}`);await page.locator('.rg-ranking').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/ranking-${width}.png`});}
  await page.locator('.rg-tabs').getByRole('button',{name:'21点',exact:true}).click();
  await page.getByRole('button',{name:'玩法与赔率',exact:true}).click();
  const rules=await page.locator('.rg-rules').innerText();assert(rules.includes('A＋6'));assert(rules.includes('双方都是天然 21 点'));assert.equal(await page.locator('.rg-felt-mark').count(),0);
  await page.locator('.rg-rules').screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/blackjack-rules.png`});
  await page.unroute('**/rsc/games/ranking.json*');
  await page.goto('http://rsc.test:3000/rsc/lottery',{waitUntil:'domcontentloaded'});
  await page.locator('.rg-ranking[aria-busy="false"]').waitFor();
  assert.equal(await page.locator('.rg-ranking h2').innerText(),'单期净盈利榜');
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS: seven ranking APIs, validation, public identity only, period switch, user cards, long IDs, 1360/390/320px, clarified rules and lottery ranking');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
