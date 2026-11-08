const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const base='http://rsc.test:3000',out=process.env.RSC_BROWSER_OUTPUT,c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});
 const host=await browser.newContext(),native=await browser.newContext({viewport:{width:390,height:780},hasTouch:true,locale:'zh-CN'}),login=await host.newPage(),page=await native.newPage(),errors=[],requests=[],results=[];
 let session,csrf,dropNext=false,lastDropped,lag=0;
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
   else if(msg.action==='ranking'){assert(['2048','blocks','snake','bird','hex','bricks','merge'].includes(payload.game));path='/rsc/arcade/ranking.json?game='+payload.game;}
   else if(msg.action==='start'){method='POST';path='/rsc/arcade/start.json';}
   else if(msg.action==='advance'){assert(Number.isInteger(payload.id));method='POST';path=`/rsc/arcade/${payload.id}/advance.json`;delete payload.id;}
   else throw new Error('Unexpected bridge action');
   const response=await host.request.fetch(base.replace('rsc.test','127.0.0.1')+path,{method,headers:{'Host':'rsc.test:3000','Cookie':(await host.cookies(base)).map(c=>c.name+'='+c.value).join('; '),'X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},...(method==='POST'?{data:payload}:{})});
   const body=await response.json();
   if(msg.action==='advance'&&dropNext){dropNext=false;lastDropped=msg;await receive({type:'response',id:msg.id,error:{message:'测试丢失回包'}});return;}
   if(lag&&msg.action==='advance'){await new Promise(r=>setTimeout(r,lag));}
   await receive({type:'response',id:msg.id,...(response.ok()?{result:body}:{error:{message:body.errors?.join('；')||'请求失败',status:response.status()}})});
  });
  await page.addInitScript(()=>{window.RiversideArcadeChannel={postMessage:msg=>window.nativeSend(msg)};});
  const response=await page.goto(base+'/rsc/arcade/embed',{waitUntil:'networkidle'});assert.equal(response.status(),200);assert.equal(response.headers()['cache-control'],'no-store');
  await page.locator('.ra-card').first().waitFor();console.log('Embed lobby ready');assert.equal(await page.locator('.ra-card').count(),7);assert.equal((await native.cookies()).length,0);
  async function command(action){const id=action+'-'+Date.now();await receive({type:'command',id,action});for(let i=0;i<100;i++){const r=results.find(r=>r.id===id);if(r)return r;await new Promise(r=>setTimeout(r,100));}throw new Error('Command timeout: '+action);}
  for(const [game,name] of [['2048','2048'],['blocks','方块堆叠'],['snake','贪吃蛇'],['bird','河畔飞鸟'],['hex','六角消除'],['bricks','打砖块'],['merge','合成大河畔']]){
   console.log('Checking',game);await page.locator('.ra-card').filter({hasText:name}).click();await page.getByRole('button',{name:'开始挑战',exact:true}).click();
   await page.waitForFunction(()=>document.querySelector('[data-action=pause]')?.hidden===false);
   const canvas=page.locator('.ra-canvas');
   if(game==='2048'){for(const key of ['ArrowLeft','ArrowDown','ArrowRight','ArrowUp'])await canvas.press(key);}
   else if(game==='bird'){await canvas.tap();}
   else if(game==='bricks'||game==='merge'){const r=await canvas.boundingBox();await page.touchscreen.tap(r.x+r.width*.7,r.y+r.height*.5);}
   else if(game==='snake'){await canvas.press('ArrowUp');}
   else{await page.locator('.ra-controls [data-key=r]').tap();assert(await page.locator('.ra-stage .ra-controls').count());}
   await page.waitForTimeout(300);
   assert((await command('pause')).result.saved,game+' saved on background');
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
  assert.equal(await frame.locator('.ra-card').count(),7,'same-origin iframe renders shared UI');
  assert.equal(await frame.locator('html').getAttribute('data-theme'),'dark');
  const priorTheme=await frame.locator('html').getAttribute('data-theme');
  await frame.locator('html').evaluate(()=>{window.postMessage({channel:'riverside.arcade',protocol:1,type:'init',payload:{theme:'light'}},location.origin);window.RiversideArcadeHost.receive({type:'init',payload:{theme:'light'}});});
  assert.equal(await frame.locator('html').getAttribute('data-theme'),priorTheme,'child messages/native receive do not initialize iframe mode');
  assert((await parent.evaluate(()=>window.seen)).includes('initialized'));await parent.close();
  console.log('PASS public shell, cookie-free native bridge, seven games, input, background save/resume, retry after committed/lost reply, exit drain, layouts and no JS/CSP errors');
 }catch(e){fs.writeFileSync(out+'/embed-failure.txt',await page.locator('body').innerText());throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
