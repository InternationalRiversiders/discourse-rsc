import assert from 'node:assert/strict';
import Core from '../../assets/javascripts/discourse/lib/arcade-core.js';
const q=()=>Array.from({length:100},(_,i)=>713+i*7919);
const bird=(version,x,y)=>{const s=Core.create('bird',q(),version);s.next=1000;s.y=y;s.vy=-3;s.pipes=[{x:x+25,gap:2500,half:750,passed:false}];Core.step(s);return s;};
assert(bird(2,850,1850).over,'legacy rectangular collider preserved');
assert(!bird(3,850,1850).over,'body inset permits wing clearance');
assert(!bird(3,1001,1800).over,'rounded corner permits grazing');
assert(bird(3,850,1790).over,'body crossing pipe still fails');
assert(bird(3,850,1650).over,'cannot fly through pipe');
const s=Core.create('merge',q());
s.balls=[{id:0,level:2,x:1700,y:5000,vx:55,vy:30},{id:1,level:3,x:2050,y:5210,vx:0,vy:0}];s.serial=2;
const start=structuredClone(s);for(let i=0;i<60;i++)Core.step(s);
assert(s.balls.some(b=>Math.abs(b.angle)>0),'glancing contact produces visible spin');
assert.deepEqual(Core.advance(start,60,[]),s,'spin and collisions replay exactly');
for(const b of s.balls){assert(Number.isInteger(b.spin)&&Number.isInteger(b.angle));assert(b.x>=Core.radii[b.level]&&b.x<=4000-Core.radii[b.level]);}
const dense=Core.create('merge',q());dense.balls=Array.from({length:80},(_,i)=>({id:i,level:i%4,x:150+(i%10)*370,y:1800+Math.floor(i/10)*400,vx:i%2?30:-30,vy:0}));dense.serial=80;
for(let i=0;i<600&&!dense.over;i++){
 Core.step(dense);
 for(const b of dense.balls){for(const k of ['x','y','vx','vy','spin','angle'])assert(Number.isFinite(b[k])&&Number.isInteger(b[k]));assert(Math.abs(b.vx)<=180&&Math.abs(b.vy)<=180&&Math.abs(b.spin)<=3000,'dense contacts stay bounded');}
}
console.log('PASS bird body/corner clearance, actual impacts, merge spin, integer deterministic replay and dense-pile stability');
