import assert from 'node:assert/strict';
import fs from 'node:fs';
import {randomUUID} from 'node:crypto';
const root=new URL('../../assets/javascripts/discourse/',import.meta.url);
const url=source=>'data:text/javascript;base64,'+Buffer.from(source).toString('base64');
const coreUrl=url(fs.readFileSync(new URL('lib/arcade-core.js',root),'utf8'));
const {default:Core}=await import(coreUrl);
const {default:Playback}=await import(url(fs.readFileSync(new URL('lib/arcade-playback.js',root),'utf8').replace('"./arcade-core"',JSON.stringify(coreUrl))));
const {default:Effects}=await import(url(fs.readFileSync(new URL('lib/arcade-effects.js',root),'utf8')));
let serial=0;
function run(game){return {id:++serial,game,status:'playing',version:0,state:Core.create(game,Array(20).fill(3733))};}
function server(r,request){
 const state=Core.advance(r.state,request.frames,request.events);
 state.q.push(...Array(Math.max(0,20-state.q.length)).fill(716));
 return {...r,state,version:r.version+1,status:state.over||request.finish?'finished':'playing'};
}
function view(r){const v=structuredClone(r);if(r.game==='2048'){delete v.state.q;}return v;}
function comparable(state){const v=structuredClone(state);delete v.q;return v;}
for(const game of Core.games.filter(g=>!['2048','sudoku'].includes(g))){
 let authoritative=run(game);const p=new Playback(view(authoritative));
 for(let i=0;i<10;i++)p.advance();
 const first=p.checkpoint(randomUUID());
 for(let i=0;i<20;i++){if(i===5)p.input(game==='bird'?'tap':game==='blocks'?'u':'l');p.advance();}
 assert.equal(p.state.tick,30,game+' runs while request in flight');
 const before=comparable(p.state),tail=structuredClone(p.events);
 authoritative=server(authoritative,first);p.acknowledge(view(authoritative));
 assert.deepEqual(comparable(p.state),before,game+' ack preserves predicted tail');
 assert.deepEqual(p.events,tail,game+' tail inputs retained');
 authoritative=server(authoritative,p.checkpoint(randomUUID(),true));p.acknowledge(view(authoritative));
 assert.deepEqual(comparable(p.state),comparable(authoritative.state),game+' final replay');
}
{
 let r=run('2048');const p=new Playback(view(r));
 for(const k of ['l','d','r','u','l','d'])p.input(k);
 for(let i=0;i<6;i++){
  assert(p.advance());const req=p.checkpoint(randomUUID());assert(!p.advance(),'must not guess private tile');
  r=server(r,req);p.acknowledge(view(r));assert(!('q' in p.state),'no future randomness');
 }
 assert.equal(r.state.tick,6);assert.equal(p.keys.length,0);
}
{
 let r=run('2048');const p=new Playback(r);
 for(const key of ['l','d','r','u']){p.input(key);assert(p.advance());}
 const req=p.checkpoint('grid-window');
 for(const key of ['l','d']){p.input(key);assert(p.advance(),'prefetched moves remain playable during network latency');}
 const predicted=comparable(p.state);assert.equal(p.state.tick,6);
 r=server(r,req);p.acknowledge(structuredClone(r));assert.deepEqual(comparable(p.state),predicted);
 const finish=p.checkpoint('grid-finish',true);r=server(r,finish);p.acknowledge(structuredClone(r));assert.deepEqual(comparable(p.state),comparable(r.state));
 assert.equal(r.state.tick,6);assert.equal(r.status,'finished');
}
{
 let r=run('2048');const p=new Playback(r);
 for(let i=0;i<50;i++){p.input(['l','d','r','u'][i%4]);p.advance();}
 assert(p.blocked,'empty window pauses without inventing random tiles');assert(p.state.tick<16);
 const req=p.checkpoint('bounded-grid'),score=p.state.score;
 r=server(r,req);p.acknowledge(structuredClone(r));assert.equal(p.state.score,score);assert(p.advance(),'refill resumes queued gestures');
}
{
 const p=new Playback(run('blocks'));p.advance();const req=p.checkpoint('retry-key');
 for(let i=0;i<200;i++)p.advance();assert.equal(p.frames,180);p.input('u');
 assert.strictEqual(p.checkpoint('different-key'),req,'retry exact immutable payload');
 const response=server(p.run,req);p.acknowledge(response);assert.equal(p.frames,180);
 p.checkpoint('tail-key');assert(p.advance(),'resume after bounded tail submitted');assert.equal(p.keys.length,0);
}
{
 const p=new Playback(run('blocks'));p.input('r');p.hold('r');for(let i=0;i<30;i++)p.advance();
 assert(p.state.piece.x>4,'held movement repeats');p.release('r');const x=p.state.piece.x;
 for(let i=0;i<10;i++)p.advance();assert.equal(p.state.piece.x,x,'release stops repeat');
}
{
 const p=new Playback(run('snake'));p.input('u');p.input('l');p.advance();assert.equal(p.state.dir,0);
 assert.deepEqual(p.keys,['l']);for(let i=0;i<7;i++)p.advance();assert.equal(p.state.dir,3,'second turn waits for next cell');
}
// Exercise the component's actual asynchronous pump with a delayed transport.
const source=fs.readFileSync(new URL('lib/arcade-app.js',root),'utf8');
const klass=source.slice(source.indexOf('export default class'),source.indexOf('export { GAMES }')).replace('export default class','return class');
const requests=[];
const request=(_action,body)=>new Promise((resolve,reject)=>requests.push({body,resolve,reject}));
const Component=new Function('GAMES','Core','Playback','Effects','draw','formatDateTime','crypto','renderArcade',klass)([],Core,Playback,Effects,()=>{},()=>'',{randomUUID},()=>{});
function component(game){const c=new Component({addEventListener(){}},{request});c.game=game;c.playback=new Playback(view(run(game)));c.run=c.playback.run;c.state=c.playback.state;c.paused=false;c.loadRanking=()=>{};return c;}
async function settle(c,r){const req=requests.shift();assert(req);const response=server(r,req.body);req.resolve(view(response));await new Promise(resolve=>setImmediate(resolve));return response;}
{
 const c=component('bird');let r=run('bird');r.id=c.run.id;
 await c.pause();assert.equal(c.syncPromise,null,'empty pause must not wedge pump');c.paused=false;
 // First request, then a tap and simulated tail during its artificial latency.
 for(let i=0;i<30;i++)c.advanceFrame();c.flush();assert(c.syncing);
 c.input('tap');for(let i=0;i<20;i++)c.advanceFrame();
 assert.equal(c.playback.state.tick,50);assert(c.playback.events.some(e=>e[1]==='tap'));
 const done=c.finish();r=await settle(c,r);assert(requests[0].body.finish,'finish drains tail after pending ack');
 r=await settle(c,r);await done;assert.equal(c.run.status,'finished');assert.deepEqual(comparable(c.state),comparable(r.state));
}
{
 const c=component('2048');let r=run('2048');r.id=c.run.id;
 for(const key of ['l','d','r','u','l','d'])c.input(key);
 assert.equal(requests.length,1);assert.equal(c.playback.keys.length,5,'queue swipes during sync');
 for(let i=0;i<6;i++)r=await settle(c,r);
 assert.equal(c.run.version,6);assert.equal(c.playback.keys.length,0);assert.equal(c.syncPromise,null);
}
{
 const c=component('blocks');let r=run('blocks');r.id=c.run.id;
 for(let i=0;i<10;i++)c.advanceFrame();c.flush();const lost=requests.shift();r=server(r,lost.body);
 c.input('r');for(let i=0;i<20;i++)c.advanceFrame();lost.reject(new Error('offline'));
 await new Promise(resolve=>setImmediate(resolve));assert(c.paused);assert.equal(c.playback.frames,20);
 const retry=c.retry();const same=requests.shift();assert.deepEqual(same.body,lost.body);
 same.resolve(view(r));await new Promise(resolve=>setImmediate(resolve));
 r=await settle(c,r);await retry;assert(!c.paused);assert.equal(c.playback.frames,0);assert.deepEqual(comparable(c.state),comparable(r.state));
}
assert.equal(requests.length,0);
console.log('PASS seven-game reconciliation, legacy private 2048 and prefetched window, bounded backlog, held controls, snake turns, delayed sync, finish drain and lost-response retry');
