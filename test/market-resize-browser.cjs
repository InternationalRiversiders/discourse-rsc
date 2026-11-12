const assert=require('node:assert/strict'),fs=require('node:fs');
const {chromium}=require(process.env.RSC_PLAYWRIGHT);
(async()=>{const browser=await chromium.launch({headless:true,args:['--no-sandbox']});try{
 const page=await browser.newPage({viewport:{width:1440,height:900}}),errors=[];page.on('pageerror',e=>errors.push(e.message));
 const css=fs.readFileSync(process.env.RSC_RESIZE_CSS,'utf8'),js=fs.readFileSync('assets/javascripts/discourse/lib/rsc-market-resize.js','utf8');
 await page.route('http://resize.test/**',r=>r.fulfill({contentType:'text/html',body:`<style>:root{--primary:#222;--secondary:white;--primary-low:#ddd;--primary-medium:#888;--tertiary:#6058cb;--tertiary-low:#eeedfa}body{margin:20px;font:16px sans-serif}${css}</style><div class="rsc-app" data-section="market"><div class="rsc-workbench detail-open"><div class="rsc-market-main"><section class="rsc-card">市场行情</section></div><div class="rsc-market-resizer" role="separator" tabindex="0" aria-orientation="vertical" aria-label="调整行情列表和详情宽度"><span></span></div><div class="rsc-market-layout"><section class="rsc-card">个股行情<input value="123.45"></section></div></div></div><script type="module">${js.replace('export default function','function')};window.cleanup=attachMarketResize(document.querySelector('[role=separator]'));</script>`}));
 await page.goto('http://resize.test/');await page.waitForFunction(()=>window.cleanup);
 const main=page.locator('.rsc-market-main'),bar=page.getByRole('separator');
 const width=async()=> (await main.boundingBox()).width;
 const start=await width(),box=await bar.boundingBox();
 await page.mouse.move(box.x+10,box.y+50);await page.mouse.down();await page.mouse.move(box.x+140,box.y+50,{steps:8});await page.mouse.up();assert((await width())>start+100);
 const saved=await width();await page.reload();await page.waitForFunction(()=>window.cleanup);assert(Math.abs((await width())-saved)<2,'remember split');
 await bar.focus();await page.keyboard.press('ArrowLeft');assert((await width())<saved);await page.keyboard.press('End');assert((await page.locator('.rsc-market-layout').boundingBox()).width>=329);
 await page.keyboard.press('Home');assert((await width())>=279);await page.keyboard.press('Enter');assert(Math.abs((await width())-start)<2);
 await bar.dblclick();assert(Math.abs((await width())-start)<2);
 const b=await bar.boundingBox();await page.mouse.move(b.x+10,b.y+50);await page.mouse.down();await page.mouse.move(b.x+80,b.y+50);await page.keyboard.press('Escape');await page.mouse.up();assert(Math.abs((await width())-start)<2,'escape cancels drag');
 assert.equal(await page.locator('input').inputValue(),'123.45','layout must not reset the order draft');
 for(const w of [1920,1100,1024,390,320]){await page.setViewportSize({width:w,height:900});await page.waitForTimeout(30);assert(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth+1),'overflow '+w);assert.equal(await bar.isVisible(),w>=1100);if(w===390||w===1920)await page.screenshot({path:`${process.env.RSC_BROWSER_OUTPUT}/resize-${w}.png`});}
 await page.setViewportSize({width:1440,height:900});await page.waitForTimeout(30);assert(Math.abs((await width())-start)<2);
 await page.evaluate(()=>cleanup());assert.equal(await page.evaluate(()=>document.documentElement.classList.contains('rsc-market-resizing')),false);
 assert.deepEqual(errors,[]);console.log('PASS dragging, persistence, keyboard, min widths, reset/cancel, draft preservation, mobile breakpoints and cleanup');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
