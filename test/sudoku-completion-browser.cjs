// UI-only regression: the authoritative acknowledgement must not skip the
// completion feedback or let rapid input leak into the next puzzle.
const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
const root=path.resolve(__dirname,'..'),manifest=JSON.parse(fs.readFileSync(root+'/public/arcade/embed-manifest.json'));
const bundle=fs.readFileSync(root+'/public/arcade/'+path.basename(manifest.script),'utf8').split('const {arcadeRequest}=')[0]+'window.Test={ArcadeApp,Core};})();';
(async()=>{
 const browser=await chromium.launch({headless:true,args:['--no-sandbox']});
 try{
 for(const width of [390,1440]){
  const page=await browser.newPage({viewport:{width,height:900}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
  await page.route('https://test.local/**',r=>r.fulfill({contentType:'text/html',body:'<style>:root{--primary:#263640;--primary-low:#ddd;--secondary:#fff;--tertiary:#6255c9;--tertiary-low:#eceafa;--primary-very-low:#fafafa}</style><div class="ra-app" id="app"></div>'}));
  await page.goto('https://test.local/');
  await page.addStyleTag({path:root+'/public/arcade/'+path.basename(manifest.stylesheet)});
  await page.addScriptTag({content:bundle});
  await page.evaluate(()=>{
   const {Core,ArcadeApp}=window.Test;
   const solved='534678912672195348198342567859761423426853791713924856961537284287419635345286179'.split('').map(Number);
   let state=Core.create('sudoku',[],4);const puzzle=solved.slice();puzzle[80]=0;Core.sudokuLoad(state,puzzle);
   let run={id:1,game:'sudoku',version:0,status:'playing',state};window.advances=0;
   window.app=new ArcadeApp(document.querySelector('#app'),{game:'sudoku',request:async(action,payload)=>{
    if(action==='ranking')return {rows:[]};
    if(action==='start')return structuredClone(run);
    if(action==='advance'){
     window.advances++;state=Core.advance(state,payload.frames,payload.events);
     if(state.awaiting)Core.sudokuLoad(state,puzzle);
     run={...run,state,version:run.version+1,status:payload.finish?'finished':'playing'};
     return structuredClone(run);
    }
   }});
  });
  await page.locator('[data-action=start]').click();
  await page.locator('[data-cell="80"]').click();await page.keyboard.press('9');
  await page.waitForFunction(()=>window.app.state.level===2);
  assert.equal(await page.locator('.ra-sudoku-complete strong').innerText(),'第 1 关完成');
  assert.equal(await page.locator('[data-cell="80"]').innerText(),'9');
  assert.equal(await page.evaluate(()=>window.advances),1,'save should already be acknowledged');
  await page.keyboard.press('9');assert.equal(await page.evaluate(()=>window.app.state.board[80]),0,'input blocked during celebration');
  await page.waitForTimeout(700);assert(await page.locator('.ra-sudoku-complete').isVisible());
  if(process.env.RSC_BROWSER_OUTPUT)await page.screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/complete-${width}.png`});
  await page.waitForFunction(()=>!window.app.sudokuCompletion);
  assert.equal(await page.locator('[data-cell="80"]').innerText(),'');
  assert.equal(await page.locator('.ra-progress').innerText(),'第 2 关');
  await page.keyboard.press('9');await page.waitForFunction(()=>window.app.state.level===3);
  await page.locator('[data-action=pause]').click();await page.waitForTimeout(1900);
  assert.equal(await page.evaluate(()=>window.app.paused),true,'transition must not resume paused game');
  assert.equal(await page.evaluate(()=>window.app.state.score),2);
  assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));
  assert.deepEqual(errors,[]);await page.close();console.log(`Sudoku completion / next level / input lock / pause: ${width}px passed`);
 }
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exitCode=1});
