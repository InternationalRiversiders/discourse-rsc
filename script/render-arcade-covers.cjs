// Export the same lobby artwork for native catalogs. Names are content-addressed.
const fs=require('node:fs'),path=require('node:path'),crypto=require('node:crypto');
const {chromium}=require(process.env.RSC_PLAYWRIGHT||'playwright');
const root=path.resolve(__dirname,'..'),lib=path.join(root,'assets/javascripts/discourse/lib');
(async()=>{const browser=await chromium.launch({headless:true,args:['--no-sandbox']});try{
 const page=await browser.newPage({deviceScaleFactor:2});
 await page.route('http://covers.local/**',route=>{
  const url=new URL(route.request().url()).pathname;
  if(url==='/')return route.fulfill({contentType:'text/html',body:'<canvas id="cover"></canvas><script type="module">import drawCover from "/arcade-cover"; import {loadMergeSprites} from "/arcade-sprites";window.render=async game=>{await loadMergeSprites();drawCover(document.querySelector("canvas"),game);await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));return document.querySelector("canvas").toDataURL("image/webp",0.9);};</script>'});
  if(/^\/arcade-[a-z]+(?:\.js)?$/.test(url))return route.fulfill({contentType:'text/javascript',body:fs.readFileSync(path.join(lib,url.slice(1).replace(/\.js$/,'')+'.js'))});
  if(/^\/plugins\/discourse-rsc\/arcade\/merge\/[a-z0-9-]+\.png$/.test(url))return route.fulfill({contentType:'image/png',body:fs.readFileSync(path.join(root,'public/arcade/merge',path.basename(url)))});
  return route.abort();
 });
 await page.goto('http://covers.local/');await page.waitForFunction(()=>window.render);
 const out=path.join(root,'public/arcade/covers');fs.mkdirSync(out,{recursive:true});const manifest={};
 for(const game of ['2048','blocks','snake','bird','hex','bricks','merge','sudoku']){
  const data=Buffer.from((await page.evaluate(g=>window.render(g),game)).split(',')[1],'base64');
  const name=`${game}-${crypto.createHash('sha256').update(data).digest('hex').slice(0,12)}.webp`;
  fs.writeFileSync(path.join(out,name),data);manifest[game]='/plugins/discourse-rsc/arcade/covers/'+name;console.log(game,data.length);
 }
 fs.writeFileSync(path.join(out,'manifest.json'),JSON.stringify(manifest,null,2)+'\n');
}finally{await browser.close();}})().catch(e=>{console.error(e);process.exitCode=1});
