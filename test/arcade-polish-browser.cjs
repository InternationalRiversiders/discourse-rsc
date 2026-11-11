const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
const root=path.resolve(__dirname,'..'),manifest=JSON.parse(fs.readFileSync(root+'/public/arcade/embed-manifest.json'));
const bundle=fs.readFileSync(root+'/public/arcade/'+path.basename(manifest.script),'utf8').split('const {arcadeRequest}=')[0]+'window.Test={ArcadeApp,Core};})();';
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
 try{for(const width of [320,390,1440]){
 const page=await browser.newPage({viewport:{width,height:900},hasTouch:width<500,isMobile:width<500});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('https://test.local/**',r=>r.fulfill({contentType:'text/html',body:'<meta name="viewport" content="width=device-width,initial-scale=1"><style>:root{--primary:#263640;--primary-low:#ddd;--secondary:#fff;--tertiary:#6255c9;--tertiary-low:#eceafa;--primary-very-low:#fafafa}</style><div class="ra-app" id="app"></div>'}));
 await page.goto('https://test.local/');await page.addStyleTag({path:root+'/public/arcade/'+path.basename(manifest.stylesheet)});await page.addScriptTag({content:bundle});
 await page.evaluate(()=>{
 const {Core,ArcadeApp}=window.Test;let run;
 window.app=new ArcadeApp(document.querySelector('#app'),{request:async(action,p)=>{
  if(action==='ranking')return {rows:[]};
  if(action==='start'){run={id:1,game:p.game,version:0,status:'playing',state:Core.create(p.game,Array.from({length:128},(_,i)=>713+i*7919),5)};return structuredClone(run);}
  if(action==='advance'){const state=Core.advance(run.state,p.frames,p.events);state.q.push(...Array(Math.max(0,128-state.q.length)).fill(7));run={...run,state,version:run.version+1,status:p.finish||state.over?'finished':'playing'};return structuredClone(run);}
 }});
 });
 for(const game of ['2048','blocks','snake','hex','bricks','bird']){
  await page.evaluate(g=>window.app.open(g),game);await page.locator('[data-action=start]').click();
  if(game==='2048'){await page.locator('[data-action=touchKeys]').click();assert(await page.locator('.ra-controls').isVisible());await page.locator('[data-key=l]').click();await page.waitForFunction(()=>window.app.state.tick>0);}
  if(game==='blocks'){
   assert.equal(await page.locator('.ra-block-previews>div').count(),2);assert(await page.locator('.ra-piece-preview .is-filled').count()>=4);
   await page.locator('canvas').focus();await page.keyboard.press('z');await page.waitForFunction(()=>window.app.state.piece.rotation===3);
   await page.keyboard.press('x');await page.waitForFunction(()=>window.app.state.piece.rotation===0);
   await page.keyboard.press('c');await page.waitForFunction(()=>window.app.state.holdShape!==undefined);
   if(width<500){const drop=await page.locator('[data-key=drop]').boundingBox(),right=await page.locator('[data-key=r]').boundingBox();assert(drop.x>right.x+right.width,'hard drop separated from arrows');}
  }
  if(game==='hex'){await page.locator('.ra-rules summary').click();assert(await page.locator('.ra-hex-demo').isVisible());}
  await page.locator('[data-action=pause]').click();
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),game+' overflow '+width);
  if(process.env.RSC_BROWSER_OUTPUT)await page.screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/${game}-${width}.png`});
 }
 assert.deepEqual(errors,[]);await page.close();console.log(`Arcade controls / previews / guidance / layout ${width}px passed`);
 }}finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
