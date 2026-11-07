const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const base='http://rsc.test:3000',out=process.env.RSC_BROWSER_OUTPUT,c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS)).admin;
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--disable-webgl','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});
 const p=await browser.newPage({viewport:{width:1360,height:1000},locale:'zh-CN'}),errors=[];let catalogs=0;
 p.on('pageerror',e=>errors.push(e.message));p.on('request',r=>{if(r.url().includes('/arcade/catalog.json'))catalogs++;});
 try{
  await p.goto(base+'/login',{waitUntil:'networkidle'});
  assert.equal(await p.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  await p.goto(base+'/rsc/games',{waitUntil:'networkidle'});await p.locator('.ra-season-banner').waitFor();
  const sizes=async()=>p.evaluate(()=>{
   const banner=document.querySelector('.rh-banner').getBoundingClientRect(),card=document.querySelector('.ra-card,.rg-game-card').getBoundingClientRect(),art=document.querySelector('.ra-card-art,.rg-art').getBoundingClientRect();
   return {bannerX:banner.x,bannerY:banner.y,bannerW:banner.width,bannerH:banner.height,cardX:card.x,cardY:card.y,cardW:card.width,cardH:card.height,artH:art.height};
  });
  for(const width of [1360,900,700,390,320]){
   await p.setViewportSize({width,height:1000});await p.getByRole('button',{name:'休闲挑战',exact:true}).click();await p.mouse.move(0,0);await p.waitForTimeout(250);const a=await sizes();
   await p.locator('.ra-hub').screenshot({path:`${out}/challenge-hub-${width}.png`});
   await p.getByRole('button',{name:'幸运游戏',exact:true}).click();await p.mouse.move(0,0);await p.waitForTimeout(250);const b=await sizes();
   for(const key of Object.keys(a))assert(Math.abs(a[key]-b[key])<1,`${width} ${key}: ${a[key]} vs ${b[key]}`);
   assert(await p.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));await p.locator('.ra-hub').screenshot({path:`${out}/lucky-hub-${width}.png`});
  }
  assert.equal(catalogs,1,'tab changes reuse the loaded season');
  await p.getByRole('button',{name:'休闲挑战',exact:true}).click();await p.setViewportSize({width:1360,height:1000});
  await p.locator('.ra-card').filter({hasText:'2048'}).click();await p.locator('.ra-rank-tabs button.is-active').filter({hasText:'赛季排行'}).waitFor();
  assert.equal(await p.locator('.ra-free').count(),0);assert.equal(await p.locator('.ra-rank-popover').isVisible(),false);
  await p.getByLabel('排行说明',{exact:true}).click();assert(await p.locator('.ra-rank-popover').isVisible());await p.getByLabel('排行说明',{exact:true}).click();
  await p.getByRole('button',{name:'开始挑战',exact:true}).click();await p.getByRole('button',{name:'暂停',exact:true}).waitFor();
  let delayed=false;
  await p.route('**/rsc/arcade/*/advance.json',async route=>{
   const response=await route.fetch({url:route.request().url().replace('rsc.test','127.0.0.1'),headers:{...await route.request().allHeaders(),host:'rsc.test:3000'}});
   if(!delayed){delayed=true;await new Promise(resolve=>setTimeout(resolve,1500));}
   await route.fulfill({response});
  });
  for(const key of ['ArrowLeft','ArrowDown','ArrowRight','ArrowUp','ArrowLeft','ArrowDown'])await p.locator('canvas.ra-canvas').press(key);
  await p.waitForFunction(()=>document.querySelector('.ra-scorebar').textContent.includes('6 /'),{},{timeout:800});
  await p.getByRole('button',{name:'结束并保存',exact:true}).click();await p.getByRole('button',{name:'再来一局',exact:true}).waitFor();
  await p.waitForFunction(name=>Array.from(document.querySelectorAll('.ra-rank li')).some(e=>e.textContent.includes(name)),c.username);
  assert.equal(await p.locator('.ra-rank-tabs .is-active').innerText(),'赛季排行');
  await p.getByRole('button',{name:'总排行',exact:true}).click();await p.getByRole('button',{name:'刷新排行',exact:true}).click();await p.waitForTimeout(250);assert.equal(await p.locator('.ra-rank-tabs .is-active').innerText(),'总排行');
  await p.locator('.ra-layout').screenshot({path:out+'/admin-score.png'});
  assert.deepEqual(errors,[]);console.log('PASS aligned banners/covers at five widths, one catalog request across tabs, hidden explanations, no free badge, default season, six moves during delayed response, admin saved season score and explicit rank selection');
 }catch(e){await p.screenshot({path:out+'/hub-failure.png',fullPage:true});throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
