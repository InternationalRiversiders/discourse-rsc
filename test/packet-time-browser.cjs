const assert = require('node:assert/strict');
const fs = require('node:fs');
const { chromium } = require(process.env.RSC_PLAYWRIGHT);
(async () => {
 const c = JSON.parse(fs.readFileSync(process.env.RSC_BROWSER_CREDENTIALS));
 const browser = await chromium.launch({executablePath:process.env.RSC_CHROMIUM,args:['--no-sandbox','--host-resolver-rules=MAP rsc.test 127.0.0.1','--unsafely-treat-insecure-origin-as-secure=http://rsc.test:3000']});
 try {
  for (const timezoneId of ['Asia/Shanghai','America/New_York','UTC']) {
   const context = await browser.newContext({locale:'zh-CN',timezoneId,viewport:{width:390,height:1000}});
   const page = await context.newPage(); const errors=[];
   page.on('pageerror',e=>errors.push(e.message));
   await page.goto('http://rsc.test:3000/'); await page.locator('#main-outlet').waitFor();
   await page.evaluate(async c=>{
    const csrf=await(await fetch('/session/csrf.json')).json();
    const r=await fetch('/session.json',{method:'POST',headers:{'Content-Type':'application/json','X-CSRF-Token':csrf.csrf,'X-Requested-With':'XMLHttpRequest'},body:JSON.stringify({login:c.username,password:c.password})});
    if(!r.ok) throw Error('login '+r.status);
   },c.alice);
   const dates = async (root, required=true) => {
    if(required) await page.locator(root+' time[datetime]').first().waitFor();
    const result = await page.locator(root+' time[datetime]').evaluateAll(nodes=>nodes.filter(n=>n.getBoundingClientRect().width).map(n=>{
     const expected = new Intl.DateTimeFormat(undefined,{timeZone:Intl.DateTimeFormat().resolvedOptions().timeZone,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).format(new Date(n.dateTime));
     return {actual:n.getAttribute('title')||n.textContent,expected};
    }));
    if(required) assert(result.length>0,root+' has dates');
    result.forEach(r=>assert.equal(r.actual.trim(),r.expected));
   };
   await page.goto('http://rsc.test:3000'+c.packet_path);
   await page.locator('.rsc-packet-nav').waitFor();
   assert.equal(await page.locator('.rsc-heading,.rsc-tabs').count(),0,'no wallet hero or tab bar on packet');
   for(const colorScheme of ['light','dark']) {
    await page.emulateMedia({colorScheme});
    for(const width of [1440,390,320]) {
     await page.setViewportSize({width,height:1000});
     assert((await page.locator('.rsc-packet').boundingBox()).y<360,'packet starts near top');
     assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'packet overflow');
     await dates('.rsc-app');
    }
   }
   if(timezoneId==='Asia/Shanghai') {
    const claim=page.getByRole('button',{name:'领取红包',exact:true});
    if(await claim.count()) await claim.click();
    await page.getByText('你已领取 2 RSC',{exact:true}).waitFor();
    await dates('.rsc-app');
   }
   const pages=[
    ['/courses?view=course&id='+c.course_id,'.river-app',true],
    ['/rsdate?view=results','.river-app',true],
    ['/whisper?view=post&id='+c.whisper_id,'.whisper-native',true],
    ['/food?view=shop&part=reviews&id='+c.shop_id,'.food-native',true],
    ['/alumni-map?view=me','.river-app',false],
   ];
   for(const [path,root,required] of pages) {
    await page.goto('http://rsc.test:3000'+path);await page.locator(root).waitFor();
    await dates(root,required);
   }
   await page.goto('http://rsc.test:3000'+c.packet_post_path);
   await page.locator('.cooked .rsc-packet-onebox').first().waitFor();
   assert.equal(await page.locator('.cooked .rsc-packet-onebox').count(),2);
   assert.match(await page.locator('.cooked').first().innerText(),/6 RSC/);
   assert.deepEqual(errors,[]);
   console.log(timezoneId+': six plugin pages, compact packet, localized dates, native/old oneboxes passed');
   if(process.env.RSC_BROWSER_OUTPUT) await page.screenshot({path:process.env.RSC_BROWSER_OUTPUT+'/onebox-'+timezoneId.replaceAll('/','-')+'.png',fullPage:true});
   await context.close();
  }
 } finally { await browser.close(); }
})().catch(e=>{console.error(e);process.exit(1);});
