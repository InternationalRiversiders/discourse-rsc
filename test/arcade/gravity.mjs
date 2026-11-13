import assert from 'node:assert/strict';
import fs from 'node:fs';
import Core from '../../assets/javascripts/discourse/lib/arcade-core.js';
const make=(lines,version=6)=>{const s=Core.create('blocks',Array(100).fill(1),version);s.lines=lines;s.piece={shape:1,rotation:0,cells:[[0,0],[1,0],[0,1],[1,1]],x:4,y:0,color:2};return s;};
const fixtures=[];
for(const lines of [0,150,175,200,250,325,10000]){
 const initial=make(lines),end=Core.advance(initial,1,[]);fixtures.push({game:'blocks',initial,frames:1,events:[],expected:end});
}
let old=make(10000,5),fast=make(10000);Core.step(old);Core.step(fast);assert.equal(old.piece.y,0);assert.equal(fast.piece.y,18);assert.equal(fast.pieces,1);assert.equal(fast.lock,1);
for(let i=0;i<10;i++)Core.step(fast);Core.step(fast,['l']);assert.equal(fast.piece.x,3);assert.equal(fast.lock,1);
for(let i=0;i<29;i++)Core.step(fast);assert.equal(fast.pieces,2);assert.equal(fast.gravityUnits,0);
const mid=make(175);for(let i=0;i<5;i++)Core.step(mid);assert.equal(mid.piece.y,2);
// Real-time local prediction and batched server replay must agree at 20G.
const initial=make(325),local=structuredClone(initial),events=[[0,'l'],[4,'r'],[12,'u']];for(let i=0;i<20;i++)Core.step(local,events.filter(x=>x[0]===i).map(x=>x[1]));assert.deepEqual(Core.advance(initial,20,events),local);
fixtures.push({game:'blocks',initial,frames:20,events,expected:local});
fs.writeFileSync(new URL('fixtures-v6.json',import.meta.url),JSON.stringify(fixtures));
console.log('PASS gravity progression, 20G movement/lock delay, legacy rules and deterministic replay');
