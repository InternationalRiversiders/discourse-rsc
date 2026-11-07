const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const base='http://rsc.test:3000',out=process.env.RSC_BROWSER_OUTPUT,c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});
 const page=await browser.newPage({viewport:{width:390,height:844},hasTouch:true,deviceScaleFactor:2,locale:'zh-CN'}),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 let latency=0,flight=0,lost=false,committed,requests=[];
 try{
  await page.goto(base+'/login',{waitUntil:'networkidle'});
  assert.equal(await page.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  await page.goto(base+'/rsc/games',{waitUntil:'networkidle'});await page.locator('.ra-card').first().waitFor();
  // Test-only observation: access the real component, never alter its game state.
  await page.evaluate(()=>{
   const id=Object.keys(requirejs.entries).find(k=>k.endsWith('/components/rsc-arcade'));
   if(!id)throw new Error('arcade component module missing');
   const proto=require(id).default.prototype,update=proto.updateView;
   proto.updateView=function(...args){window.arcadeUnderTest=this;return update.apply(this,args);};
  });
  await page.route('**/rsc/arcade/*/advance.json',async route=>{
   flight++;const body=JSON.parse(route.request().postData());requests.push(body);
   const response=await route.fetch({url:route.request().url().replace('rsc.test','127.0.0.1'),headers:{...await route.request().allHeaders(),host:'rsc.test:3000'}});
   const data=await response.json();await new Promise(r=>setTimeout(r,latency));flight--;
   if(lost){lost=false;committed={body,data};await route.abort('connectionfailed');}else{await route.fulfill({response});}
  });
  async function open(name){await page.locator('.ra-card').filter({hasText:name}).click();await page.getByRole('button',{name:'开始挑战',exact:true}).click();await page.waitForFunction(()=>window.arcadeUnderTest?.run?.status==='playing'&&!window.arcadeUnderTest.busy);}
  async function finish(){await page.getByRole('button',{name:'结束并保存',exact:true}).click();await page.getByRole('button',{name:'再来一局',exact:true}).waitFor();await page.getByRole('button',{name:'返回挑战',exact:false}).click();await page.locator('.ra-card').first().waitFor();}
  latency=350;await open('2048');
  for(const key of ['ArrowLeft','ArrowDown','ArrowRight','ArrowUp','ArrowLeft','ArrowDown'])await page.locator('canvas.ra-canvas').press(key);
  await page.waitForFunction(()=>window.arcadeUnderTest.run.state.tick===6);
  assert.equal(await page.evaluate(()=>window.arcadeUnderTest.playback.keys.length),0,'all rapid swipes consumed');
  assert(requests.length<6,'rapid moves are batched');assert.equal(requests.reduce((sum,r)=>sum+r.frames,0),6);
  await finish();
  // Hold right without relying on browser key-repeat. Release outside the button.
  latency=0;await open('方块堆叠');const right=page.locator('.ra-controls button[aria-label="→"]');
  await right.scrollIntoViewIfNeeded();const box=await right.boundingBox();await page.mouse.move(box.x+box.width/2,box.y+box.height/2);await page.mouse.down();await page.waitForTimeout(450);await page.mouse.move(5,5);await page.mouse.up();
  const held=await page.evaluate(()=>({x:window.arcadeUnderTest.state.piece.x,held:window.arcadeUnderTest.playback.held.size}));
  assert(held.x>4,'held touch/pointer moves several columns');assert.equal(held.held,0);
  await finish();
  latency=900;requests=[];await open('河畔飞鸟');
  const cdp=await page.context().newCDPSession(page);
  // Touch the actual picture and then the panel padding, not only a small button.
  const canvas=page.locator('canvas.ra-canvas');await canvas.scrollIntoViewIfNeeded();
  const rect=await canvas.boundingBox();
  for(const point of [{x:rect.x+rect.width/2,y:rect.y+rect.height/2},{x:rect.x-5,y:rect.y+20}]){
   const count=await page.evaluate(()=>window.arcadeUnderTest.playback.events.filter(e=>e[1]==='tap').length+window.arcadeUnderTest.playback.keys.filter(k=>k==='tap').length);
   await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[point]});
   assert.equal(await page.evaluate(()=>window.arcadeUnderTest.playback.events.filter(e=>e[1]==='tap').length+window.arcadeUnderTest.playback.keys.filter(k=>k==='tap').length),count+1,'touch-down anywhere in play area flaps exactly once');
   await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
  }

  // Steer by reading the displayed local position, clicking the actual button.
  // This keeps the bird alive through multiple delayed acknowledgements.
  await page.evaluate(()=>{
   window.tapDuringSync=0;window.ticksDuringSync=new Set();
   window.pilot=setInterval(()=>{
    const c=window.arcadeUnderTest,s=c?.state;if(!s||c.inputDisabled||s.over)return;
    if(c.syncing)window.ticksDuringSync.add(s.tick);
    const pipe=s.pipes.find(p=>p.x+400>750),target=pipe?pipe.gap:2800;
    if(s.vy>=0&&s.y>target+180){
     if(c.syncing)window.tapDuringSync++;
     const b=document.querySelector('.ra-controls button');
     b.click();
    }
   },16);
  });
  await page.waitForFunction(()=>window.tapDuringSync>=1&&window.arcadeUnderTest.run.version>=1,{},{timeout:20000});
  assert(await page.evaluate(()=>window.ticksDuringSync.size>30),'simulation keeps advancing during delayed requests');
  assert.equal(await page.getByRole('button',{name:'起飞',exact:true}).isEnabled(),true);
  assert(requests.some(r=>r.events.some(e=>e[1]==='tap')));
  await page.evaluate(()=>clearInterval(window.pilot));
  // Click while the response is held, then finish before it returns. All tail
  // inputs must reach the server before the final finished response.
  await page.getByRole('button',{name:'暂停并保存',exact:true}).click();await page.waitForFunction(()=>!window.arcadeUnderTest.syncing);
  await page.locator('.ra-play').screenshot({path:out+'/arcade-slow-network.png'});
  latency=0;await finish();
  // Lost ACK after commit: replay the same request, preserve its live tail.
  await open('方块堆叠');latency=350;lost=true;
  await page.waitForFunction(()=>!!window.arcadeUnderTest.error,{},{timeout:10000});
  const before=committed;await page.getByRole('button',{name:'重试并恢复进度',exact:true}).click();
  await page.waitForFunction(()=>!window.arcadeUnderTest.error&&!window.arcadeUnderTest.syncing&&!window.arcadeUnderTest.paused);
  assert(requests.filter(r=>r.request_id===before.body.request_id).length===2,'same request retried exactly once');
  assert(await page.evaluate(()=>window.arcadeUnderTest.run.version>=1));latency=0;await finish();
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS mobile rapid swipes, captured held controls, live bird taps during 900 ms delayed sync, pause/finish drain and lost-ACK recovery');
 }catch(e){await page.screenshot({path:out+'/input-failure.png',fullPage:true});fs.writeFileSync(out+'/input-failure.txt',await page.locator('body').innerText());throw e;}
 finally{await browser.close();}
})().catch(e=>{console.error(e.message);process.exit(1);});
