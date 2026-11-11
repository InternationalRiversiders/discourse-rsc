import assert from 'node:assert/strict';
import fs from 'node:fs';
import Core from '../../assets/javascripts/discourse/lib/arcade-core.js';
const source=fs.readFileSync(new URL('../../assets/javascripts/discourse/lib/arcade-playback.js',import.meta.url),'utf8');
const url=s=>'data:text/javascript;base64,'+Buffer.from(s).toString('base64');
const coreUrl=url(fs.readFileSync(new URL('../../assets/javascripts/discourse/lib/arcade-core.js',import.meta.url),'utf8'));
const {default:Playback}=await import(url(source.replace('"./arcade-core"',JSON.stringify(coreUrl))));
const create=g=>Core.create(g,Array.from({length:128},(_,i)=>713+i*7919),5),fixtures=[];
function replay(state,frames,events){const expected=Core.advance(state,frames,events);fixtures.push({game:state.game,initial:structuredClone(state),frames,events,expected:structuredClone(expected)});return expected;}
let s=create('blocks'),shape=s.piece.shape,next=s.nextShape;
s=replay(s,1,[[0,'x:0']]);assert.equal(s.holdShape,shape);assert.equal(s.piece.shape,next);
const held=structuredClone(s.piece);s=replay(s,1,[[0,'x:0']]);assert.deepEqual(s.piece,held,'hold only once before locking');
s=replay(s,1,[[0,'drop']]);s.board.fill(0);const second=s.piece.shape;
s=replay(s,1,[[0,'x:0']]);assert.equal(s.piece.shape,shape);assert.equal(s.holdShape,second);
s=create('blocks');s=replay(s,2,[[0,'tap'],[1,'u']]);assert.equal(s.piece.rotation,0,'opposite rotations return orientation');
s.piece={shape:0,rotation:1,cells:[[2,0],[2,1],[2,2],[2,3]],x:-2,y:5,color:1};s=replay(s,1,[[0,'tap']]);assert.equal(s.piece.rotation,0);assert(s.piece.cells.every(([x])=>x+s.piece.x>=0));
s=create('bricks');s=replay(s,1,[[0,'x:3550']]);assert.equal(s.paddle,3550,'touch follows immediately');
const layouts=[];for(let i=0;i<4;i++){layouts.push(JSON.stringify(s.board));s.board.fill(0);s=replay(s,1,[]);}assert.equal(new Set(layouts).size,4);
s=create('snake');s.tick=6;s.dir=0;s.snake=[210,209,189,190,191];s=replay(s,1,[]);assert(s.over);assert.deepEqual(s.collision,{x:10,y:9});
s=create('snake');s.tick=6;s.dir=0;s.snake=[210,209,189,190];s=replay(s,1,[]);assert(!s.over,'vacating tail is safe');
s=create('hex');s.falling={lane:0,color:1,distance:1900};const slow=Core.advance(s,1,[]),fast=replay(s,1,[[0,'drop']]);assert(fast.falling.distance<slow.falling.distance);
s=create('bird');s=replay(s,1,[]);assert.equal(s.pipes[0].half,820);
let run={id:1,version:0,status:'playing',game:'2048',state:create('2048')};const p=new Playback(run);
for(let i=0;i<8;i++){p.input(['l','d','r','u'][i%4]);p.advance();}const request=p.checkpoint('same-id');
for(let i=0;i<24;i++){p.input(['l','d','r','u'][i%4]);assert(p.advance(),'play through 24 moves of network delay');}
const predicted=structuredClone(p.state);let accepted=replay(run.state,request.frames,request.events);accepted.q.push(...Array(128-accepted.q.length).fill(7));
p.acknowledge({...run,version:1,state:accepted});delete predicted.q;const actual=structuredClone(p.state);delete actual.q;assert.deepEqual(actual,predicted,'ack must not shift predicted positions');
if(process.argv.includes('--fixtures'))fs.writeFileSync(new URL('fixtures-v5.json',import.meta.url),JSON.stringify(fixtures)+'\n');
console.log('PASS v5 hold/preview/CCW kicks, direct paddle, layouts, snake collision/tail, hex acceleration, bird gap, weak-network 2048');
