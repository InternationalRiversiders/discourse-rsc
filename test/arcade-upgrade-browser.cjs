const assert=require('node:assert/strict'),fs=require('node:fs');const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{
 const base='http://rsc.test:3000',c=JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS)).admin;
 const browser=await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1',`--unsafely-treat-insecure-origin-as-secure=${base}`]});const p=await browser.newPage({viewport:{width:390,height:900},locale:'zh-CN'});
 try{
  await p.goto(base+'/login',{waitUntil:'networkidle'});assert.equal(await p.evaluate(async c=>{for(let i=0;i<2;i++){const {csrf}=await(await fetch('/session/csrf.json')).json();const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});if(r.status!==403||i===1)return r.status;}},c),200);
  await p.goto(base+'/rsc/games',{waitUntil:'networkidle'});await p.getByRole('button',{name:'街机区',exact:true}).click();await p.locator('.ra-card').filter({hasText:'2048'}).click();
  await p.locator('.ra-rank-tabs .is-active').waitFor();assert.equal(await p.locator('.ra-rank-tabs .is-active').innerText(),'赛季排行');
  assert.equal(await p.getByRole('button',{name:'本期赛季',exact:true}).count(),0);
  const response=p.waitForResponse(r=>r.url().includes('/arcade/start')&&r.status()===200);await p.getByRole('button',{name:'开始挑战',exact:true}).click();const r=await(await response).json();assert.equal(r.rules_version,2);assert(r.season_id);assert.equal(r.state.limit,null);
  await p.locator('canvas').press('ArrowLeft');await p.getByRole('button',{name:'结束并保存',exact:true}).click();await p.getByRole('button',{name:'再来一局',exact:true}).waitFor();
  await p.getByRole('button',{name:'总排行',exact:true}).click();await p.getByLabel('排行说明',{exact:true}).click();assert.equal(await p.getByRole('button',{name:'查看原规则排行',exact:true}).count(),0);
  const ranking=await p.evaluate(async()=>await(await fetch('/rsc/arcade/ranking.json?game=2048')).json());assert(ranking.rows.some(x=>x.score===600));assert(ranking.season.rows.some(x=>x.score===600));
  console.log('PASS current season directly uses endless rules and trial scores remain in both rankings');
 }finally{await browser.close();}
})().catch(e=>{console.error(e);process.exit(1);});
