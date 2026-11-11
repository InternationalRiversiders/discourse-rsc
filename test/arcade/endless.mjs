import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import Core from '../../assets/javascripts/discourse/lib/arcade-core.js';
const q=()=>Array.from({length:100},(_,i)=>713+i*7919);
// Released version 1 fixtures must remain unchanged.
for(const f of JSON.parse(fs.readFileSync(new URL('./fixtures.json',import.meta.url))))assert.deepEqual(Core.advance(f.initial,f.frames,f.events),f.expected);
for(const game of Core.games){
 const s=Core.create(game,q());assert.equal(s.version,5);assert.equal(s.limit,null);
 s.tick=Core.limits[game];Core.step(s,game==='2048'?['l']:[]);assert(!s.over,game+' still time-limited');
 if(game==='sudoku')continue; // Sudoku was introduced without a timed legacy mode.
 const legacy=Core.create(game,q(),1);legacy.tick=legacy.limit-1;Core.step(legacy,game==='2048'?['l']:[]);assert(legacy.over,game+' legacy limit changed');
}
let s=Core.create('blocks',q());s.pieces=200;s.piece={cells:[[0,0]],x:0,y:19,color:1};Core.step(s,['drop']);assert(!s.over);assert.equal(s.pieces,201);
s=Core.create('bricks',q());s.board.fill(0);s.board[0]=1;s.x=300;s.y=500;s.vx=0;s.vy=60;Core.step(s);assert.equal(s.wave,2);assert.equal(s.score,100);assert(!s.over);assert(s.board.some(Boolean));assert.equal(s.lives,3);
const second=s.board.slice();s.board.fill(0);Core.step(s);assert.equal(s.wave,3);assert.notDeepEqual(s.board,second);
for(let i=0;i<8;i++){s.board.fill(0);Core.step(s);}assert(s.board.some(n=>n>1));assert(Math.abs(s.vy)<=65);
s=Core.create('bricks',q());Core.step(s,['x:0']);assert.equal(s.paddle,450);for(let i=0;i<24;i++)Core.step(s);assert.equal(s.paddle,450);
s=Core.create('merge',q());s.next=0;Core.step(s,['x:0','drop']);assert.equal(s.balls[0].x,Core.radii[0]);assert.equal(s.cooldown,24);
s.cooldown=0;s.drops=100;Core.step(s,['x:4000','drop']);assert.equal(s.drops,101);assert(!s.over);
// No old artificial 70-body game-over; separated tiny balls fit the vessel.
s=Core.create('merge',q());s.balls=Array.from({length:72},(_,i)=>({id:i,level:0,x:130+(i%12)*300,y:800+Math.floor(i/12)*700,vx:0,vy:0}));Core.step(s);assert(!s.over);
// Continuous physics and checkpoint replay stay identical, including both walls.
s=Core.create('merge',q());s.balls=Array.from({length:100},(_,i)=>({id:i,level:i%3,x:150+(i%10)*370,y:800+Math.floor(i/10)*440,vx:i%2?30:-30,vy:0}));s.serial=100;
let local=structuredClone(s);const before=performance.now();for(let i=0;i<180;i++){if(local.over)break;Core.step(local);}
let frames=local.tick-s.tick;const replay=Core.advance(s,frames,[]);assert.deepEqual(local,replay);console.log('100-body merge batch ms',Math.round(performance.now()-before));
s=Core.create('bird',q());s.score=1000;Core.step(s);assert.equal(s.pipes[0].half,600);assert.equal(s.pipes[0].x,4160);
// SDK includes both rule versions and retains deterministic cross-runtime results.
const manifest=JSON.parse(fs.readFileSync(new URL('../../public/arcade/manifest.json',import.meta.url)));
const sdk=fs.readFileSync(new URL('../../public/arcade/'+manifest.script.split('/').pop(),import.meta.url),'utf8');const sandbox={};vm.createContext(sandbox);vm.runInContext(sdk,sandbox);assert.equal(sandbox.RiversideArcade.rulesVersion,5);
console.log('PASS both rules versions, uncapped play, recurring brick waves, bounded drag, edge drops, long deterministic physics');
