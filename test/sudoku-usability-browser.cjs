const fs=require('fs'),path=require('path'),assert=require('node:assert/strict');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
const root=path.resolve(__dirname,'..'),manifest=JSON.parse(fs.readFileSync(root+'/public/arcade/embed-manifest.json'));
const bundle=fs.readFileSync(root+'/public/arcade/'+path.basename(manifest.script),'utf8').split('const {arcadeRequest}=')[0]+'window.Test={ArcadeApp,Core};})();';
(async()=>{const browser=await chromium.launch({headless:true,args:['--no-sandbox']});try{
for(const width of [320,390,1440])for(const dark of [false,true]){
 const page=await browser.newPage({viewport:{width,height:900}});const errors=[];page.on('pageerror',e=>errors.push(e.message));
 await page.route('https://test.local/**',r=>r.fulfill({contentType:'text/html',body:`<style>:root{--primary:${dark?'#ddd':'#263640'};--primary-low:#888;--primary-medium:#888;--secondary:${dark?'#20232a':'#fff'};--tertiary:#8075df;--tertiary-low:#8075df33;--primary-very-low:#8882}</style><div class="ra-app" id="app"></div>`}));
 await page.goto('https://test.local/');await page.evaluate(d=>document.documentElement.dataset.theme=d?'dark':'light',dark);await page.addStyleTag({path:root+'/public/arcade/'+path.basename(manifest.stylesheet)});await page.addScriptTag({content:bundle});
 await page.evaluate(()=>{const {Core,ArcadeApp}=window.Test;let run={id:1,game:'sudoku',version:0,status:'playing',state:Core.sudokuLoad(Core.create('sudoku',[],5),Array(81).fill(0))};window.app=new ArcadeApp(document.querySelector('#app'),{game:'sudoku',request:async(action,payload)=>{if(action==='ranking')return {rows:[]};if(action==='start')return structuredClone(run);if(action==='advance'){run={...run,version:run.version+1,state:Core.advance(run.state,payload.frames,payload.events)};return structuredClone(run);}}});});
 await page.locator('[data-action=start]').click();
 await page.locator('[data-cell="1"]').click();await page.keyboard.press('n');await page.keyboard.press('3');
 await page.locator('[data-cell="0"]').click();await page.keyboard.press('n');await page.keyboard.press('3');
 await page.waitForFunction(()=>window.app.state.board[0]===3);assert.equal(await page.evaluate(()=>window.app.state.notes[1]),0);
 await page.keyboard.press('Control+z');await page.waitForFunction(()=>window.app.state.board[0]===0);assert.equal(await page.evaluate(()=>window.app.state.notes[1]),8);
 await page.keyboard.press('3');await page.waitForFunction(()=>window.app.state.board[0]===3);
 page.once('dialog',d=>d.dismiss());await page.locator('[data-action=reset]').click();assert.equal(await page.evaluate(()=>window.app.state.board[0]),3);
 page.once('dialog',d=>d.accept());await page.locator('[data-action=reset]').click();await page.waitForFunction(()=>window.app.state.board[0]===0);assert.equal(await page.evaluate(()=>window.app.state.score),0);
 for(let i=0;i<9;i++){await page.locator(`[data-cell="${i}"]`).click();await page.keyboard.press('1');}
 await page.waitForFunction(()=>window.app.state.board.filter(n=>n===1).length===9);
 assert(await page.locator('[data-action=digit][data-arg="1"]').evaluate(e=>e.classList.contains('is-exhausted')));
 await page.locator('[data-cell="9"]').click();await page.locator('[data-action=digit][data-arg="1"]').click();assert.equal(await page.evaluate(()=>window.app.state.board[9]),0);
 assert.equal(await page.locator('.is-same').count(),9);
 assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1));assert.deepEqual(errors,[]);
 if(process.env.RSC_BROWSER_OUTPUT)await page.screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/sudoku-${width}-${dark?'dark':'light'}.png`});
 await page.close();console.log(`PASS Sudoku notes, undo, confirmation, counts, highlight, layout: ${width}px ${dark?'dark':'light'}`);
}}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
