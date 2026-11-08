import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import crypto from 'node:crypto';
const root=new URL('../../',import.meta.url);
const source=fs.readFileSync(new URL('assets/javascripts/discourse/lib/arcade-effects.js',root),'utf8');
const {default:Effects,tileTracks}=await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'));
assert.deepEqual(tileTracks([2,2,2,2,...Array(12).fill(0)],'l').map(t=>[t.from,t.to]),[[0,0],[1,0],[2,1],[3,1]]);
assert.deepEqual(tileTracks([2,0,0,2,...Array(12).fill(0)],'r').map(t=>t.to),[3,3]);
const manifest=JSON.parse(fs.readFileSync(new URL('public/arcade/manifest.json',root)));
const bundle=fs.readFileSync(new URL('public/arcade/'+manifest.script.split('/').pop(),root),'utf8');
assert.equal(crypto.createHash('sha256').update(bundle).digest('hex'),manifest.sha256);
const context=vm.createContext({performance,window:{devicePixelRatio:2}});vm.runInContext(bundle,context);
const SDK=context.RiversideArcade;assert.equal(SDK.rulesVersion,4);assert.equal(SDK.protocol,1);
const fixtures=['fixtures.json','fixtures-v2.json','fixtures-v3.json','fixtures-v4.json'].flatMap(name=>JSON.parse(fs.readFileSync(new URL('test/arcade/'+name,root))));
const ctx=new Proxy({},{get:(_target,key)=>key==='measureText'?()=>({width:20}):key==='createLinearGradient'?()=>({addColorStop(){}}):()=>{},set:()=>true});
const canvas={width:0,height:0,style:{},getContext:()=>ctx};
for(const f of fixtures){
 const actual=SDK.Core.advance(f.initial,f.frames,f.events);
 assert.deepEqual(JSON.parse(JSON.stringify(actual)),f.expected,'SDK matches server fixture '+f.game);
 const snapshot=JSON.stringify(actual);
 for(const reducedMotion of [false,true]){
  const effects=new SDK.Effects({reducedMotion});effects.observe(f.initial,null,0);effects.observe(actual,null,50);
  SDK.draw(canvas,actual,effects,60);SDK.draw(canvas,actual,effects,600);
 }
 assert.equal(JSON.stringify(actual),snapshot,'presentation never mutates '+f.game);
}
const e=new Effects();e.observe({game:'2048',tick:0,score:0,board:[2,2,...Array(14).fill(0)]},null,0);
e.observe({game:'2048',tick:1,score:4,board:[4,...Array(15).fill(0)]},{board:[2,2,...Array(14).fill(0)],direction:'l'},10);
assert.equal(e.motion.tracks.length,2);assert.equal(e.scoreGain.amount,4);assert(e.pop(0,180)>1);
console.log('PASS SDK/server fixtures, animation tracks, reduced motion and seven immutable renderers');
let requests=0,fail=false;
context.Image=class{set src(url){requests++;this.complete=true;this.naturalWidth=52;queueMicrotask(()=>fail?this.onerror():this.onload());}};
const sprites=await SDK.loadMergeSprites('/test/');assert.equal(sprites.length,11);assert.equal(requests,11);await SDK.loadMergeSprites('/test/');assert.equal(requests,11,'reuse loaded originals');
fail=true;assert((await SDK.loadMergeSprites('/retry/')).every(i=>!i));fail=false;assert((await SDK.loadMergeSprites('/retry/')).every(Boolean),'failed images can retry on next open');
for(const asset of manifest.assets){const data=fs.readFileSync(new URL('public/arcade/merge/'+asset.url.split('/').pop(),root));assert.equal(crypto.createHash('sha256').update(data).digest('hex'),asset.sha256);}
console.log('PASS all eleven asset hashes, loader cache and failed-image retry');
