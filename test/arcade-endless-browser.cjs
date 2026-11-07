const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const base='http://rsc.test:3000',out=process.env.RSC_BROWSER_OUTPUT,c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--disable-webgl','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});
 const p=await browser.newPage({viewport:{width:390,height:844},hasTouch:true,deviceScaleFactor:2,locale:'zh-CN'}),errors=[];p.on('pageerror',e=>errors.push(e.message));
 try{
  await p.goto(base+'/login',{waitUntil:'networkidle'});assert.equal(await p.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  await p.goto(base+'/rsc/games',{waitUntil:'networkidle'});await p.getByRole('button',{name:'街机区',exact:true}).click();
  await p.evaluate(()=>{const id=Object.keys(requirejs.entries).find(k=>k.endsWith('/components/rsc-arcade'));const proto=require(id).default.prototype,update=proto.updateView;proto.updateView=function(...args){window.arcadeUnderTest=this;return update.apply(this,args);};});
  async function open(name){await p.locator('.ra-card').filter({hasText:name}).click();await p.getByRole('button',{name:'开始挑战',exact:true}).click();await p.waitForFunction(()=>window.arcadeUnderTest?.run?.status==='playing'&&!window.arcadeUnderTest.busy);}
  async function finish(){if(await p.getByRole('button',{name:'结束并保存',exact:true}).count())await p.getByRole('button',{name:'结束并保存',exact:true}).click();await p.getByRole('button',{name:'再来一局',exact:true}).waitFor();await p.getByRole('button',{name:'返回挑战',exact:false}).click();}
  for(const name of ['打砖块','六角消除']){
   await open(name);await p.locator('.ra-controls').scrollIntoViewIfNeeded();
   const left=await p.getByRole('button',{name:'←',exact:true}).boundingBox(),right=await p.getByRole('button',{name:'→',exact:true}).boundingBox();
   assert(right.x-(left.x+left.width)>=60,'thumb controls must be separated');assert(left.height>=60&&right.height>=60);
   if(name==='打砖块'){
    await p.locator('canvas.ra-canvas').scrollIntoViewIfNeeded();const rect=await p.locator('canvas.ra-canvas').boundingBox();
    const cdp=await p.context().newCDPSession(p);
    await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:rect.x+rect.width-15,y:rect.y+rect.height*.7}]});
    await p.waitForTimeout(350);await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});
    assert(await p.evaluate(()=>window.arcadeUnderTest.state.paddle>2900),'touch drag moves paddle');
   }
   await p.getByRole('button',{name:'暂停并保存',exact:true}).click();await p.waitForFunction(()=>!window.arcadeUnderTest.syncing);
   assert.equal(await p.evaluate(()=>window.arcadeUnderTest.state.limit),null);
   await p.locator('.ra-play').screenshot({path:out+'/endless-'+name+'.png'});await finish();
  }
  await open('合成大河畔');const rect=await p.locator('canvas.ra-canvas').boundingBox();await p.locator('canvas.ra-canvas').click({position:{x:2,y:60}});await p.waitForTimeout(250);
  await p.getByRole('button',{name:'暂停并保存',exact:true}).click();await p.waitForFunction(()=>!window.arcadeUnderTest.syncing);
  const before=await p.evaluate(()=>JSON.parse(JSON.stringify(window.arcadeUnderTest.run)));
  assert.equal(before.rules_version,2);assert(before.state.balls[0].x<500,'drop reaches the actual wall');
  await p.locator('.ra-play').screenshot({path:out+'/endless-merge.png'});
  await p.reload({waitUntil:'networkidle'});await p.locator('.ra-card').filter({hasText:'合成大河畔'}).click();
  const start=p.waitForResponse(r=>r.url().includes('/arcade/start')&&r.status()===200);await p.getByRole('button',{name:'开始挑战',exact:true}).click();const resumed=await(await start).json();
  assert.equal(resumed.id,before.id);assert.deepEqual(resumed.state,before.state);
  // Return to the server checkpoint, not a fresh random game.
  await p.getByRole('button',{name:'结束并保存',exact:true}).click();await p.getByRole('button',{name:'再来一局',exact:true}).waitFor();
  assert.deepEqual(errors,[]);console.log('PASS spaced thumb controls, real touch paddle, no timer, wall-adjacent drops, exact saved-state reload');
 }catch(e){await p.screenshot({path:out+'/endless-failure.png',fullPage:true});throw e;}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
