const assert=require('node:assert/strict'),fs=require('node:fs');const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const base='http://rsc.test:3000',c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS)),out=process.env.RSC_BROWSER_OUTPUT;
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});
 try{
  const page=await browser.newPage({viewport:{width:390,height:844},isMobile:true,hasTouch:true,deviceScaleFactor:3,colorScheme:'dark'});const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.goto(base+'/login',{waitUntil:'networkidle'});
  const status=await page.evaluate(async c=>{const {csrf}=await(await fetch('/session/csrf.json')).json();return(await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf},body:JSON.stringify({login:c.username,password:c.password})})).status;},c);assert.equal(status,200);
  await page.goto(base+'/rsc/games',{waitUntil:'networkidle'});await page.locator('.ra-card').first().waitFor();await page.locator('.ra-hub').screenshot({path:out+'/arcade-dark-mobile.png'});
  await page.locator('.ra-card').filter({hasText:'2048'}).tap();const startResponse=page.waitForResponse(r=>r.url().includes('/arcade/start')&&r.status()===200);await page.getByRole('button',{name:'开始挑战',exact:true}).tap();const started=await(await startResponse).json();
  assert.equal(await page.locator('.ra-controls').count(),0);let response,state;
  const box=await page.locator('canvas.ra-canvas').boundingBox(),cdp=await page.context().newCDPSession(page);
  response=page.waitForResponse(r=>r.url().includes('/advance')&&r.status()===200);
  await cdp.send('Input.dispatchTouchEvent',{type:'touchStart',touchPoints:[{x:box.x+box.width/2,y:box.y+box.height/3}]});
  await cdp.send('Input.dispatchTouchEvent',{type:'touchMove',touchPoints:[{x:box.x+box.width/2,y:box.y+box.height*2/3}]});
  await cdp.send('Input.dispatchTouchEvent',{type:'touchEnd',touchPoints:[]});state=await(await response).json();assert.equal(state.version,started.version+1);
  await page.reload({waitUntil:'networkidle'});await page.locator('.ra-card').filter({hasText:'2048'}).tap();response=page.waitForResponse(r=>r.url().includes('/arcade/start')&&r.status()===200);await page.getByRole('button',{name:'开始挑战',exact:true}).tap();const resumed=await(await response).json();assert.equal(resumed.id,started.id);assert.equal(resumed.version,state.version);
  await page.locator('.ra-play').screenshot({path:out+'/arcade-2048-touch.png'});assert.equal(errors.length,0,errors.join('\n'));console.log('PASS direct canvas swipes, high-DPI mobile, dark mode, reload/resume');
 }finally{await browser.close();}
})().catch(e=>{console.error(String(e.message).split('Call log:')[0]);process.exit(1);});
