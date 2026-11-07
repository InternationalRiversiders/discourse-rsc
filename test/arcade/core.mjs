import assert from 'node:assert/strict';
import Core from '../../assets/javascripts/discourse/lib/arcade-core.js';
const q=()=>Array.from({length:40},(_,i)=>713+i*7919);
// Replay every game across batch boundaries, including server-issued queue refills.
for(const game of Core.games){
 let s=Core.create(game,q()),client=structuredClone(s),count=0;
 while(!s.over&&count<1200){
  const events=[],frames=game==='2048'?1:Math.min(60,1200-count);
  let n=0;
  for(;n<frames&&!client.over&&client.q.length>=4;n++){
   const keys=game==='2048'?[['l','d','r','u'][count%4]]:game==='blocks'&&n%25===0?['drop']:game==='bird'&&n%22===0?['tap']:game==='merge'&&n===0?['drop']:game==='hex'&&n%17===0?['r']:[];
   keys.forEach(k=>events.push([n,k]));Core.step(client,keys);
  }
  s=Core.advance(s,n,events);assert.deepEqual(s,client,game+' mismatch');
  const refill=q().slice(0,Math.max(0,20-s.q.length));s.q.push(...refill);client.q.push(...refill);count+=n;
 }
 assert(Number.isInteger(s.score)&&s.score>=0);console.log(game, 'frames',count,'score',s.score,'PASS');
}
let s=Core.create('2048',q());s.board=[2,2,2,2,...Array(12).fill(0)];s=Core.advance(s,1,[[0,'l']]);assert.equal(s.score,8);assert.deepEqual(s.board.slice(0,2),[4,4]);
s=Core.create('2048',q());s.board=[2,4,2,4,4,2,4,2,2,4,2,4,4,2,4,2];s=Core.advance(s,1,[[0,'l']]);assert(s.over);
assert.throws(()=>Core.advance(s,181,[]));assert.throws(()=>Core.advance(s,1,[[1,'l']]));assert.throws(()=>Core.advance(s,1,[[0,'hack']]));
s=Core.create('blocks',q());s.board.fill(1,190);s.board[199]=0;s.piece={cells:[[0,0]],x:9,y:19,color:2};s=Core.advance(s,1,[[0,'drop']]);assert.equal(s.lines,1);assert.equal(s.score,100);
s=Core.create('snake',q());s.tick=6;s.snake=[0,1,2];s.dir=3;assert(Core.advance(s,1,[]).over);
s=Core.create('merge',q());s.balls=[{id:0,x:2000,y:4000,level:0,vx:0,vy:0},{id:1,x:2000,y:4000,level:0,vx:0,vy:0}];s=Core.advance(s,1,[]);assert.equal(s.balls.length,1);assert.equal(s.score,20);
console.log('PASS scoring, collision, limits and invalid-input checks');
