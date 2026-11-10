const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const base='http://rsc.test:3000',out=process.env.RSC_BROWSER_OUTPUT,c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});
 const context=await browser.newContext({viewport:{width:1440,height:1000},locale:'zh-CN'}),page=await context.newPage(),errors=[];
 page.on('pageerror',e=>errors.push(e.message));
 try{
  await page.goto(base+'/login',{waitUntil:'networkidle'});
  assert.equal(await page.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  await page.goto(base+'/rsc/games',{waitUntil:'networkidle'});
  await page.locator('.ra-card').first().waitFor();assert.equal(await page.locator('.ra-card').count(),8);
  for(const width of [1440,390,320]){
   await page.setViewportSize({width,height:1000});
   const a=await page.locator('.ra-season-banner').boundingBox();
   await page.locator('[data-action=seasonInfo]').click();assert.equal(await page.locator('.ra-prize-grid>div').count(),20);
   assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'forum season overflow '+width);
   await page.screenshot({path:`${out}/forum-season-${width}.png`});
   await page.locator('[data-action=seasonInfo]').click();
   await page.getByRole('button',{name:'博弈区',exact:true}).click();await page.locator('.rl-banner').waitFor();
   const b=await page.locator('.rl-banner').boundingBox();assert(Math.abs(a.width-b.width)<2);assert(Math.abs(a.height-b.height)<2,'matching banners');
   await page.getByRole('button',{name:'街机区',exact:true}).click();await page.locator('.ra-card').first().waitFor();
  }
  await page.locator('.ra-card').filter({hasText:'数独'}).click();
  await page.getByRole('button',{name:'开始挑战',exact:true}).click();await page.locator('[data-action=pause]').waitFor();
  const cell=page.locator('[data-cell]:not(.is-given)').first();await cell.click();await cell.press('n');await cell.press('5');
  assert.equal(await cell.locator('.ra-sudoku-notes').innerText(),'5');
  await page.getByRole('button',{name:'暂停并保存',exact:true}).click();await page.waitForFunction(()=>document.querySelector('[data-action=start]').disabled===false);
  await page.screenshot({path:out+'/forum-sudoku-320.png'});
  await page.getByRole('button',{name:'返回挑战',exact:false}).click();await page.locator('.ra-card').filter({hasText:'数独'}).click();await page.getByRole('button',{name:'开始挑战',exact:true}).click();await page.locator('[data-action=pause]').waitFor();
  assert.equal(await page.locator('.ra-sudoku-notes').allInnerTexts().then(a=>a.filter(Boolean).join('')),'5','saved notes restored');
  await page.getByRole('button',{name:'暂停并保存',exact:true}).click();
  assert.equal(errors.length,0,errors.join('\n'));
  console.log('PASS real forum compiled assets: eight games, equal banners, twenty-place details, 320/390/1440 layouts, keyboard notes, save/resume, no JS errors');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
