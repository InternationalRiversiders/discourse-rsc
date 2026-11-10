const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const base='http://rsc.test:3000',out=process.env.RSC_BROWSER_OUTPUT,c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});
 const host=await browser.newContext(),native=await browser.newContext({viewport:{width:390,height:780},hasTouch:true,locale:'zh-CN'}),login=await host.newPage(),page=await native.newPage(),errors=[],requests=[],results=[];
 let session,csrf,dropNext=false,lastDropped,lag=0;const states={};
 page.on('pageerror',e=>errors.push(e.message));
 page.on('console',m=>{if(m.type()==='error'&&/Content Security Policy|Refused to/.test(m.text()))errors.push(m.text());});
 try{
  const enginePage=await host.newPage();
  await enginePage.route('**/rsc-engine-check',route=>route.fulfill({contentType:'text/html',body:'<!doctype html><title>Engine check</title>'}));
  await enginePage.goto(base+'/rsc-engine-check');
  const manifest=JSON.parse(fs.readFileSync(__dirname+'/../public/arcade/manifest.json'));
  await enginePage.addScriptTag({url:base+manifest.script});
  const fixtures=['fixtures.json','fixtures-v2.json','fixtures-v3.json','fixtures-v4.json'].flatMap(name=>JSON.parse(fs.readFileSync(__dirname+'/arcade/'+name)));
  const checks=await enginePage.evaluate(fixtures=>fixtures.map(f=>JSON.stringify(window.RiversideArcade.Core.advance(f.initial,f.frames,f.events))),fixtures);
  checks.forEach((actual,i)=>assert.deepEqual(JSON.parse(actual),fixtures[i].expected,'Chromium replay '+fixtures[i].game));
  await enginePage.close();console.log('Chromium/Node replay fixtures agree');
  await login.goto(base+'/login',{waitUntil:'networkidle'});
  assert.equal(await login.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  csrf=await login.evaluate(async()=>(await(await fetch('/session/csrf.json')).json()).csrf);
  // A native-host simulation. Authenticated requests run OUTSIDE the cookie-free
  // WebView; the embedded document receives neither passwords nor API keys.
  async function receive(msg){return page.evaluate(m=>window.RiversideArcadeHost.receive(m),{channel:'riverside.arcade',protocol:1,session,...msg});}
  await page.exposeBinding('nativeSend',async(_source,raw)=>{
   const msg=JSON.parse(raw);
   if(msg.type==='ready'){session=msg.session;await receive({type:'init',payload:{theme:'light'}});return;}
   if(msg.type==='command-result'){results.push(msg);return;}
   if(msg.type!=='request'){return;}
   requests.push(msg);const payload={...msg.payload};
   let path,method='GET';
   if(msg.action==='catalog')path='/rsc/arcade/catalog.json';
   else if(msg.action==='ranking'){assert(['2048','blocks','snake','bird','hex','bricks','merge','sudoku'].includes(payload.game));path='/rsc/arcade/ranking.json?game='+payload.game;}
   else if(msg.action==='start'){method='POST';path='/rsc/arcade/start.json';}
   else if(msg.action==='advance'){assert(Number.isInteger(payload.id));method='POST';path=`/rsc/arcade/${payload.id}/advance.json`;delete payload.id;}
   else throw new Error('Unexpected bridge action');
   const response=await host.request.fetch(base.replace('rsc.test','127.0.0.1')+path,{method,headers:{'Host':'rsc.test:3000','Cookie':(await host.cookies(base)).map(c=>c.name+'='+c.value).join('; '),'X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},...(method==='POST'?{data:payload}:{})});
   const body=await response.json();if(body.game&&body.state)states[body.game]=body.state;
   if(msg.action==='advance'&&dropNext){dropNext=false;lastDropped=msg;await receive({type:'response',id:msg.id,error:{message:'测试丢失回包'}});return;}
   if(lag&&msg.action==='advance'){await new Promise(r=>setTimeout(r,lag));}
   await receive({type:'response',id:msg.id,...(response.ok()?{result:body}:{error:{message:body.errors?.join('；')||'请求失败',status:response.status()}})});
  });
  await page.addInitScript(()=>{window.RiversideArcadeChannel={postMessage:msg=>window.nativeSend(msg)};});
  const response=await page.goto(base+'/rsc/arcade/embed',{waitUntil:'networkidle'});assert.equal(response.status(),200);assert.equal(response.headers()['cache-control'],'no-store');
  await page.locator('.ra-card').first().waitFor();console.log('Embed lobby ready');assert.equal(await page.locator('.ra-card').count(),8);assert.equal((await native.cookies()).length,0);
  for(const width of [320,390,1440]){
   await page.setViewportSize({width,height:850});
   await page.locator('[data-action=seasonInfo]').click();assert.equal(await page.locator('.ra-prize-grid>div').count(),20);
   assert.equal(await page.locator('.rh-banner-metric strong').innerText(),'316 RSC');
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'banner no overflow '+width);
   await page.screenshot({path:`${out}/season-details-${width}.png`});
   await page.locator('[data-action=seasonInfo]').click();assert(await page.locator('.ra-season-details').isHidden());
  }
  await page.setViewportSize({width:390,height:780});
  async function command(action){const id=action+'-'+Date.now();await receive({type:'command',id,action});for(let i=0;i<100;i++){const r=results.find(r=>r.id===id);if(r)return r;await new Promise(r=>setTimeout(r,100));}throw new Error('Command timeout: '+action);}
  for(const [game,name] of [['2048','2048'],['blocks','方块堆叠'],['snake','贪吃蛇'],['bird','河畔飞鸟'],['hex','六角消除'],['bricks','打砖块'],['merge','合成大河畔'],['sudoku','数独']]){
   console.log('Checking',game);await page.locator('.ra-card').filter({hasText:name}).click();await page.getByRole('button',{name:'开始挑战',exact:true}).click();
   await page.waitForFunction(()=>document.querySelector('[data-action=pause]')?.hidden===false);
   const canvas=game==='sudoku'?page.locator('[data-cell]').first():page.locator('.ra-canvas');
   if(game==='sudoku'){
    const initial=states.sudoku.givens,cell=initial.indexOf(0),square=page.locator(`[data-cell="${cell}"]`);
    await square.tap();await page.locator('[data-action=note]').tap();await page.locator('[data-action=digit][data-arg="2"]').tap();
    assert.equal(await square.locator('.ra-sudoku-notes').innerText(),'2');
    await square.press('n');await square.press('3');assert.equal(await square.innerText(),'3');
    await square.press('Control+z');assert.equal(await square.locator('.ra-sudoku-notes').innerText(),'2');
    const saved=await command('pause');assert(saved.result.saved);assert.equal(states.sudoku.notes[cell],4);
    assert((await command('resume')).result.saved);await page.getByRole('button',{name:'继续挑战',exact:true}).click();
    assert.equal(await square.locator('.ra-sudoku-notes').innerText(),'2');
    for(const width of [320,390,1440])for(const theme of ['light','dark']){
     await page.setViewportSize({width,height:850});await page.evaluate(t=>document.documentElement.dataset.theme=t,theme);
     assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'sudoku layout '+width);
     const rect=await page.locator('.ra-sudoku-grid').boundingBox();assert(rect.width>230);assert(Math.abs(rect.width-rect.height)<8);
     await page.screenshot({path:`${out}/sudoku-${theme}-${width}.png`});
    }
    await page.setViewportSize({width:390,height:780});
    function solve(board){const b=board.slice();function visit(){const i=b.indexOf(0);if(i<0)return true;for(let n=1;n<=9;n++){if(b.some((v,j)=>v===n&&(Math.floor(j/9)===Math.floor(i/9)||j%9===i%9||(Math.floor(j/27)===Math.floor(i/27)&&Math.floor(j%9/3)===Math.floor(i%9/3)))))continue;b[i]=n;if(visit())return true;}b[i]=0;return false;}assert(visit());return b;}
    const answer=solve(initial);lag=400;
    for(let i=0;i<81;i++)if(!initial[i]){await page.locator(`[data-cell="${i}"]`).click();await page.locator(`[data-cell="${i}"]`).press(String(answer[i]));}
    await page.waitForFunction(()=>document.querySelector('.ra-progress').textContent==='第 2 关');
    assert.equal(await page.locator('.ra-scorebar strong').innerText(),'1');assert.equal(states.sudoku.score,1);lag=0;
   }
   else if(game==='2048'){for(const key of ['a','s','d','Shift+W'])await canvas.press(key);}
   else if(game==='bird'){await canvas.tap();}
   else if(game==='bricks'||game==='merge'){const r=await canvas.boundingBox();await page.touchscreen.tap(r.x+r.width*.7,r.y+r.height*.5);}
   else if(game==='snake'){await canvas.press('w');}
   else{await page.locator('.ra-controls [data-key=r]').tap();assert(await page.locator('.ra-stage .ra-controls').count());}
   await page.waitForTimeout(300);
   lag=700;
   await canvas.press('Escape');
   assert(await page.getByRole('button',{name:'继续挑战',exact:true}).isVisible(),game+' Escape pauses before network save');
   await canvas.press('Escape');
   assert(await page.getByRole('button',{name:'继续挑战',exact:true}).isVisible(),game+' repeated Escape does not resume');
   assert((await command('pause')).result.saved,game+' saved on background');
   lag=0;
   assert((await command('resume')).result.saved,game+' refreshed checkpoint');
   assert(await page.getByRole('button',{name:'继续挑战',exact:true}).isVisible());
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),game+' no overflow');
   await page.screenshot({path:`${out}/embed-${game}.png`});
   await page.getByRole('button',{name:'结束并保存',exact:true}).click();await page.getByRole('button',{name:'再来一局',exact:true}).waitFor();
   await page.getByRole('button',{name:'返回挑战',exact:false}).click();
  }
  await page.locator('.ra-card').filter({hasText:'2048'}).click();await page.getByRole('button',{name:'开始挑战',exact:true}).click();await page.waitForFunction(()=>document.querySelector('[data-action=pause]')?.hidden===false);
  dropNext=true;
  for(const key of ['ArrowLeft','ArrowDown','ArrowRight','ArrowUp'])await page.locator('.ra-canvas').press(key);
  await page.getByRole('button',{name:'重试并恢复进度'}).waitFor();assert(lastDropped);
  const prior=requests.length;await page.getByRole('button',{name:'重试并恢复进度'}).click();
  await page.waitForFunction(()=>document.querySelector('.rg-error').hidden);
  assert.deepEqual(requests.slice(prior).find(r=>r.action==='advance').payload,lastDropped.payload,'lost reply retries original checkpoint');
  lag=700;await page.locator('.ra-canvas').press('ArrowLeft');
  assert((await command('exit')).result.saved,'exit drains in-flight checkpoint');
  assert(await page.locator('#arcade').evaluate(e=>e.inert));
  assert(!JSON.stringify(requests).includes(c.password));assert.equal(errors.length,0,errors.join('\n'));
  // Single-game embeds delegate navigation to the App by default, without an
  // init capability flag. The normal lobby above retains its own navigation.
  lag=0;
  await page.goto(base+'/rsc/arcade/embed?game=2048',{waitUntil:'networkidle'});
  await page.locator('.ra-canvas[data-game="2048"]').waitFor();
  assert.equal(await page.locator('.ra-heading').count(),0,'no duplicate game title');
  assert.equal(await page.locator('[data-action=back]').count(),0,'no embedded lobby back button');
  await page.getByRole('button',{name:'开始挑战',exact:true}).click();
  await page.waitForFunction(()=>document.querySelector('[data-action=pause]')?.hidden===false);
  for(const key of ['ArrowLeft','ArrowDown','ArrowRight','ArrowUp'])await page.locator('.ra-canvas').press(key);
  assert((await command('pause')).result.saved,'single-game background saves');
  assert((await command('resume')).result.saved,'single-game resume restores');
  assert((await command('exit')).result.saved,'single-game App back saves before exit');
  assert(await page.locator('#arcade').evaluate(e=>e.inert));
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS default single-game navigation with pause/resume/exit; no opt-in flag');
  const parent=await host.newPage();
  await parent.route('**/embed-host-test',route=>route.fulfill({contentType:'text/html',body:`<!doctype html><iframe title="arcade" src="/rsc/arcade/embed?mode=iframe"></iframe><script>
   window.seen=[];window.addEventListener('message',async e=>{
    const frame=document.querySelector('iframe');if(e.origin!==location.origin||e.source!==frame.contentWindow)return;
    const m=e.data;window.seen.push(m.type);if(m.channel!=='riverside.arcade'||m.protocol!==1)return;
    if(m.type==='ready'){frame.contentWindow.postMessage({...m,type:'init',payload:{theme:'dark'}},location.origin);}
    if(m.type==='request'&&m.action==='catalog'){
     const response=await fetch('/rsc/arcade/catalog.json');frame.contentWindow.postMessage({...m,type:'response',result:await response.json()},location.origin);
    }
   });</script>`}));
  await parent.goto(base+'/embed-host-test');
  const frame=parent.frameLocator('iframe');await frame.locator('.ra-card').first().waitFor();
  assert.equal(await frame.locator('.ra-card').count(),8,'same-origin iframe renders shared UI');
  assert.equal(await frame.locator('html').getAttribute('data-theme'),'dark');
  const priorTheme=await frame.locator('html').getAttribute('data-theme');
  await frame.locator('html').evaluate(()=>{window.postMessage({channel:'riverside.arcade',protocol:1,type:'init',payload:{theme:'light'}},location.origin);window.RiversideArcadeHost.receive({type:'init',payload:{theme:'light'}});});
  assert.equal(await frame.locator('html').getAttribute('data-theme'),priorTheme,'child messages/native receive do not initialize iframe mode');
  assert((await parent.evaluate(()=>window.seen)).includes('initialized'));await parent.close();
  console.log('PASS public shell, cookie-free native bridge, eight games, input, background save/resume, retry after committed/lost reply, exit drain, layouts and no JS/CSP errors');
 }catch(e){fs.writeFileSync(out+'/embed-failure.txt',await page.locator('body').innerText());throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
