import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
const source=await readFile(new URL('../assets/javascripts/discourse/lib/game-3d-scenes.js',import.meta.url),'utf8');
const {scenePixelRatio}=await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
assert.equal(scenePixelRatio(350,300,{dpr:3}),2.5);
assert.equal(scenePixelRatio(350,300,{dpr:3,moving:true}),2);
assert.equal(scenePixelRatio(680,380,{dpr:2}),2);
assert.equal(scenePixelRatio(680,380,{dpr:1}),1.25);
assert.equal(scenePixelRatio(0,0,{dpr:3}),1);
for(const [w,h] of [[350,300],[680,380],[1200,1600],[5000,3000]]) {
 for(const moving of [false,true]) {
  const r=scenePixelRatio(w,h,{dpr:4,moving,maxSize:4096});
  assert(w*h*r*r<=(moving?1250000:2000000)+1);
  assert(w*r<=4096 && h*r<=4096);
 }
}
console.log('PASS: HiDPI resolution, animation budget, normal display supersampling, GPU dimensions, zero-size host');
