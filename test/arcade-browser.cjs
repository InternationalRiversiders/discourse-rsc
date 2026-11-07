const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const base='http://rsc.test:3000',out=process.env.RSC_BROWSER_OUTPUT,c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});
 const page=await browser.newPage({viewport:{width:1360,height:1100},locale:'zh-CN'}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(base+'/login',{waitUntil:'networkidle'});
  assert.equal(await page.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  await page.goto(base+'/rsc/games',{waitUntil:'networkidle'});await page.locator('.ra-card').first().waitFor();assert.equal(await page.locator('.ra-card').count(),7);
  for(const width of [1360,390,320]){await page.setViewportSize({width,height:1000});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),`catalog overflow ${width}`);await page.locator('.ra-hub').screenshot({path:`${out}/arcade-lobby-${width}.png`});}
  await page.setViewportSize({width:1360,height:1100});
  await page.locator('.ra-card').filter({hasText:'2048'}).click();
  let response=page.waitForResponse(r=>r.url().includes('/arcade/start')&&r.status()===200);await page.getByRole('button',{name:'开始挑战',exact:true}).click();let run=await(await response).json();assert(run.state.q.length<=20);assert(!JSON.stringify(run).includes('seed'));
  for(const key of ['ArrowLeft','ArrowDown','ArrowRight','ArrowUp','ArrowLeft','ArrowDown']){response=page.waitForResponse(r=>r.url().includes('/advance')&&r.status()===200);await page.locator('canvas.ra-canvas').press(key);run=await(await response).json();await page.waitForFunction(()=>document.querySelector('.ra-scorebar [role=status]').textContent!=='同步进度');}
  // Lose a response AFTER the server committed it, then replay the exact request.
  let committed,body;
  await page.route('**/rsc/arcade/*/advance.json',async route=>{body=route.request().postData();const r=await route.fetch({url:route.request().url().replace('rsc.test','127.0.0.1'),headers:{...await route.request().allHeaders(),host:'rsc.test:3000'}});committed=await r.json();await route.abort('connectionfailed');await page.unroute('**/rsc/arcade/*/advance.json');});
  await page.locator('canvas.ra-canvas').press('ArrowLeft');await page.getByRole('button',{name:'重试并恢复进度'}).waitFor();response=page.waitForResponse(r=>r.url().includes('/advance')&&r.status()===200);await page.getByRole('button',{name:'重试并恢复进度'}).click();const retried=await(await response).json();assert.equal(retried.version,committed.version);assert.equal(retried.state.score,committed.state.score);
  await page.getByRole('button',{name:'结束并保存',exact:true}).click();await page.getByRole('button',{name:'再来一局',exact:true}).waitFor();await page.waitForFunction(username=>Array.from(document.querySelectorAll('.ra-rank li')).some(row=>row.textContent.includes(username)),c.username);await page.getByRole('button',{name:'返回挑战',exact:false}).click();await page.locator('.ra-card').first().waitFor();
  for(const name of ['方块堆叠','贪吃蛇','河畔飞鸟','六角消除','打砖块','合成大河畔']){
   await page.locator('.ra-card').filter({hasText:name}).click();await page.getByRole('button',{name:'开始挑战',exact:true}).click();await page.getByRole('button',{name:'暂停',exact:true}).waitFor();
   await page.locator('canvas.ra-canvas').press(name==='方块堆叠'?'Space':name==='河畔飞鸟'?'Space':'ArrowRight');
   await page.waitForTimeout(300);
   if(name==='合成大河畔'){await page.locator('canvas.ra-canvas').click({position:{x:170,y:80}});}
   await page.locator('.ra-layout').screenshot({path:`${out}/arcade-${name}.png`});
   if(await page.getByRole('button',{name:'结束并保存',exact:true}).count()){await page.getByRole('button',{name:'结束并保存',exact:true}).click();}
   await page.getByRole('button',{name:'再来一局',exact:true}).waitFor();assert.equal(await page.locator('.rg-error').count(),0,name);
   await page.setViewportSize({width:320,height:1000});assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),name+' overflow');await page.locator('.ra-play').screenshot({path:`${out}/arcade-${name}-mobile.png`});await page.setViewportSize({width:1360,height:1100});
   await page.getByRole('button',{name:'返回挑战',exact:false}).click();await page.locator('.ra-card').first().waitFor();
  }
  await page.getByRole('button',{name:'幸运游戏',exact:true}).click();assert.equal(await page.locator('.rg-game-card').count(),6);await page.reload({waitUntil:'networkidle'});assert.equal(await page.locator('.rg-game-card').count(),6);
  await page.locator('.rg-game-card').filter({hasText:'抛硬币'}).click();await page.getByRole('button',{name:'玩法与赔率',exact:true}).click();assert((await page.locator('.rg-rules').innerText()).includes('返还 2 倍'));
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS seven live games, shared server validation, lost-response idempotency, bounded 2048 prefetch, mobile layouts, keyboard/touch controls and lucky-game regression');
 }catch(e){await page.screenshot({path:`${out}/failure.png`,fullPage:true});console.log('Browser errors',errors);console.log('Page', (await page.locator('body').innerText()).slice(-2300));console.log(e.stack?.split('\n').slice(-4).join('\n'));throw e;}finally{await browser.close();}
})().catch(e=>{console.error(String(e.message).split('Call log:')[0]);process.exit(1);});
