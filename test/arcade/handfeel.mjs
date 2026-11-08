import assert from 'node:assert/strict';
import fs from 'node:fs';
import Core from '../../assets/javascripts/discourse/lib/arcade-core.js';
import Effects from '../../assets/javascripts/discourse/lib/arcade-effects.js';
const q=()=>Array.from({length:200},(_,i)=>713+i*7919);
const create=g=>Core.create(g,q());
const url=s=>'data:text/javascript;base64,'+Buffer.from(s).toString('base64');
const coreUrl=url(fs.readFileSync(new URL('../../assets/javascripts/discourse/lib/arcade-core.js',import.meta.url),'utf8'));
const {default:Playback}=await import(url(fs.readFileSync(new URL('../../assets/javascripts/discourse/lib/arcade-playback.js',import.meta.url),'utf8').replace('"./arcade-core"',JSON.stringify(coreUrl))));
const fixture=[];
function sample(initial,frames,events=[]){const expected=Core.advance(initial,frames,events);fixture.push({game:initial.game,initial:structuredClone(initial),frames,events,expected:structuredClone(expected)});return expected;}
// Finite angular rest: settled piles stop visually, not just rounded velocity.
let s=create('merge');s.balls=Array.from({length:30},(_,i)=>({id:i,level:i%4,x:450+i%6*600,y:2600+Math.floor(i/6)*480,vx:i%2?30:-30,vy:0}));s.serial=30;
sample(s,180);
for(let i=0;i<1800;i++)Core.step(s);
assert(s.balls.every(b=>b.rest===45&&b.spin===0));
const angles=s.balls.map(b=>b.angle);for(let i=0;i<1800;i++)Core.step(s);
assert.deepEqual(s.balls.map(b=>b.angle),angles,'settled pile must not rotate at all');
assert(s.balls.every(b=>b.precise.every(Number.isSafeInteger)));
// Removing a support wakes the top ball; sleeping is not a frozen collider.
s=create('merge');s.balls=[{id:0,level:10,x:2000,y:4635,vx:0,vy:0},{id:1,level:2,x:2000,y:3585,vx:0,vy:0}];
for(let i=0;i<300;i++)Core.step(s);
assert(s.balls.every(b=>b.rest===45));const top=s.balls.find(b=>b.id===1);const y=top.y;s.balls=[top];for(let i=0;i<10;i++)Core.step(s);assert(s.balls[0].y>y+30);assert.equal(s.balls[0].rest,0);
// New impact wakes a settled fruit and transfers tangential momentum.
s=create('merge');s.balls=[{id:0,level:3,x:2000,y:5265,vx:0,vy:0}];for(let i=0;i<90;i++)Core.step(s);
s.balls.push({id:1,level:2,x:1630,y:5200,vx:70,vy:0});Core.step(s);assert.equal(s.balls[0].rest,0);assert(Math.abs(s.balls[0].vx)>0);
s=create('merge');s.balls=[{id:0,level:0,x:2000,y:4000,vx:0,vy:0},{id:1,level:0,x:2100,y:4000,vx:0,vy:0}];
const effects=new Effects();effects.observe(s,null,0);s=sample(s,1);effects.observe(s,null,20);assert.equal(effects.bursts.length,1);assert.equal(effects.pops.size,1);effects.observe(s,null,25);assert.equal(effects.bursts.length,1,'no duplicate merge feedback');
// A bag has each shape once; color belongs to shape rather than piece count.
s=create('blocks');const bag=[];for(let i=0;i<14;i++){bag.push(s.piece.shape);assert.equal(s.piece.color,s.piece.shape+1);Core.step(s,['drop']);s.board.fill(0);}
assert.deepEqual([...bag.slice(0,7)].sort(),[0,1,2,3,4,5,6]);assert.deepEqual([...bag.slice(7)].sort(),[0,1,2,3,4,5,6]);
s=create('blocks');s.piece={shape:1,rotation:0,cells:[[0,0],[1,0],[0,1],[1,1]],x:4,y:18,color:2};s.fall=0;const count=s.pieces;
for(let i=0;i<29;i++)Core.step(s);assert.equal(s.pieces,count);Core.step(s,['l']);assert.equal(s.lock,1,'ground adjustment resets lock delay');
for(let i=0;i<29;i++)Core.step(s);assert.equal(s.pieces,count+1);assert.equal(s.fall,0,'new piece owns gravity timer');
s=create('blocks');s.piece={shape:0,rotation:1,cells:[[2,0],[2,1],[2,2],[2,3]],x:-2,y:5,color:1};s=sample(s,1,[[0,'u']]);assert.equal(s.piece.rotation,2);assert(s.piece.cells.every(([x])=>x+s.piece.x>=0),'SRS line wall kick');
const pieces=s.pieces;Core.step(s,['drop']);assert.equal(s.pieces,pieces+1,'hard drop locks immediately');
// Upgrade an old save without throwing away its current piece/board.
s=Core.create('blocks',q(),3);s.version=4;s=sample(s,60,[[0,'u'],[1,'l']]);assert.equal(s.version,4);
// First geometric contact, not brick index order; remaining tick reflects.
s=create('bricks');s.board.fill(0);s.board[0]=s.board[8]=1;s.x=300;s.y=1080;s.vx=0;s.vy=-400;s=sample(s,1);assert.equal(s.board[8],0);assert.equal(s.board[0],1);assert(s.vy>0);assert(s.y>1060);
for(const offset of [0,200,450]){s=create('bricks');s.x=s.paddle+offset;s.y=5000;s.vx=0;s.vy=45;Core.step(s);assert(s.vy<0);assert(Math.abs(Math.hypot(s.vx,s.vy)-45)<1,'paddle angle must not multiply speed');}
s=create('bricks');s.x=70;s.y=70;s.vx=-30;s.vy=-30;s=sample(s,1);assert(s.vx>0&&s.vy>0,'corner reflects both walls');
// Connected matches can bridge the wraparound side; separate colors survive.
s=create('hex');s.lanes=[[1],[2],[],[],[],[1]];s.falling={lane:0,color:1,distance:165};s=sample(s,1);assert.equal(s.score,100);assert.deepEqual(s.lanes, [[],[2],[],[],[],[]]);
// Ceiling is a boundary, not an invisible fatal obstacle.
s=create('bird');s.y=90;s=sample(s,1,[[0,'tap']]);assert(!s.over);assert.equal(s.y,85);assert.equal(s.vy,0);
s=create('snake');Core.step(s,['r']);assert(!s.turned,'same direction must not consume a turn');Core.step(s,['u']);assert.equal(s.dir,0);
const run=g=>({id:1,version:0,status:'playing',game:g,state:create(g)});
let p=new Playback(run('snake'));for(const key of ['r','r','l','u','u','l','d','r'])p.input(key);assert.deepEqual(p.keys,['u','l']);p.advance();for(let i=0;i<7;i++)p.advance();assert.equal(p.state.dir,3);
p=new Playback(run('bird'));for(let i=0;i<20;i++)p.input('tap');assert.deepEqual(p.keys,['tap']);p.advance();p.advance();assert.equal(p.state.vy,-59,'one flap per frame; no ghost backlog');
const tileEffects=new Effects(),board=[2,2,...Array(14).fill(0)];tileEffects.observe({game:'2048',tick:0,score:0,board},null,0);tileEffects.observe({game:'2048',tick:1,score:4,board:[4,0,2,...Array(13).fill(0)]},{board,direction:'l'},20);assert(tileEffects.pops.has(2),'new tile has feedback on normal tick');
if(process.argv.includes('--fixtures'))fs.writeFileSync(new URL('fixtures-v4.json',import.meta.url),JSON.stringify(fixture)+'\n');
else for(const f of JSON.parse(fs.readFileSync(new URL('fixtures-v4.json',import.meta.url))))assert.deepEqual(Core.advance(f.initial,f.frames,f.events),f.expected);
console.log('PASS v4 settling/wakeup, merge feedback, bag/kicks/lock, swept collisions, hex connectivity, ceiling, buffered input and tile appearance');
