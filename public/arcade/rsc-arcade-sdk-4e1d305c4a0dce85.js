/* Riverside Arcade: generated from the forum modules. Do not edit. */
(() => { "use strict";
const Core=(()=>{
// Shared deterministic rules. No clock, browser API, random seed or wallet access.
// All coordinates and velocities are integers. Rendering never affects simulation.
const ARCADE_VERSION = 1;
const GAME_IDS = ["2048", "blocks", "snake", "bird", "hex", "bricks", "merge"];
const LIMITS = {"2048": 2000, blocks: 18000, snake: 18000, bird: 10800, hex: 10800, bricks: 18000, merge: 18000};
const SHAPES = [[[0,0],[1,0],[2,0],[3,0]],[[0,0],[1,0],[0,1],[1,1]],[[1,0],[0,1],[1,1],[2,1]],[[1,0],[2,0],[0,1],[1,1]],[[0,0],[1,0],[1,1],[2,1]],[[0,0],[0,1],[1,1],[2,1]],[[2,0],[0,1],[1,1],[2,1]]];
const RADIUS = [110,145,185,235,295,365,445,535,635,745,865];
const clone = (s) => JSON.parse(JSON.stringify(s));
function take(s,n) { if (!s.q.length) { throw new Error("queue_empty"); } return s.q.shift()%n; }
function tile(s) { const empty=s.board.map((v,i)=>v?null:i).filter(i=>i!==null); if(empty.length){s.board[empty[take(s,empty.length)]]=take(s,10)===0?4:2;} }
function food(s) { const free=[];for(let i=0;i<400;i++){if(!s.snake.includes(i)&&!s.walls.includes(i)){free.push(i);}}if(!free.length){s.over=true;}else{s.food=free[take(s,free.length)];} }
function block(s) { s.piece={cells:clone(SHAPES[take(s,7)]),x:3,y:0,color:s.pieces%7+1};s.pieces++;if(!fits(s,s.piece)){s.over=true;} }
function fits(s,p) {return p.cells.every(([x,y])=>{x+=p.x;y+=p.y;return x>=0&&x<10&&y>=0&&y<20&&!s.board[y*10+x];});}
function lower(s) {const p={...s.piece,y:s.piece.y+1};if(fits(s,p)){s.piece=p;return true;}for(const [x,y] of s.piece.cells){s.board[(s.piece.y+y)*10+s.piece.x+x]=s.piece.color;}let lines=0;for(let y=19;y>=0;y--){if(s.board.slice(y*10,y*10+10).every(Boolean)){s.board.splice(y*10,10);s.board.unshift(...Array(10).fill(0));lines++;y++;}}s.lines+=lines;s.score+=[0,100,300,500,800][lines];if(s.pieces>=200){s.over=true;}else{block(s);}return false;}
function create(game,q) {
 if(!GAME_IDS.includes(game)){throw new Error("game");}
 const s={game,version:ARCADE_VERSION,tick:0,score:0,over:false,q:q.slice(),limit:LIMITS[game]};
 if(game==="2048"){s.board=Array(16).fill(0);tile(s);tile(s);}
 if(game==="blocks"){s.board=Array(200).fill(0);s.lines=0;s.pieces=0;block(s);}
 if(game==="snake"){s.snake=[210,209,208];s.dir=1;s.walls=[84,85,86,87,312,313,314,315];food(s);}
 if(game==="bird"){s.y=2500;s.vy=0;s.pipes=[];s.next=0;}
 if(game==="hex"){s.lanes=Array.from({length:6},()=>[]);s.rotation=0;s.falling=null;}
 if(game==="bricks"){s.x=2000;s.y=4700;s.vx=27;s.vy=-36;s.paddle=2000;s.lives=3;s.board=Array(48).fill(1);}
 if(game==="merge"){s.balls=[];s.aim=2000;s.next=take(s,4);s.drops=0;s.cooldown=0;s.danger=0;s.serial=0;}
 return s;
}
function slide(s,dir,spawn=true) {
 let changed=false;
 for(let lane=0;lane<4;lane++){
  const ids=Array.from({length:4},(_,j)=>dir==='l'?lane*4+j:dir==='r'?lane*4+3-j:dir==='u'?j*4+lane:(3-j)*4+lane);
  const values=ids.map(i=>s.board[i]).filter(Boolean), out=[];
  for(let i=0;i<values.length;i++){if(values[i]===values[i+1]){out.push(values[i]*2);s.score+=values[i]*2;i++;}else{out.push(values[i]);}}
  while(out.length<4){out.push(0);}ids.forEach((id,i)=>{if(s.board[id]!==out[i]){changed=true;}s.board[id]=out[i];});
 }
 if(changed&&spawn){tile(s);}s.over=!s.board.some((v,i)=>!v||(i%4<3&&v===s.board[i+1])||(i<12&&v===s.board[i+4]));
}
function mergePhysics(s) {
 for(const b of s.balls){b.vy=Math.min(90,b.vy+3);b.x+=b.vx;b.y+=b.vy;b.vx=Math.trunc(b.vx*98/100);const r=RADIUS[b.level];if(b.x<r){b.x=r;b.vx=Math.abs(b.vx)>>1;}if(b.x>4000-r){b.x=4000-r;b.vx=-(Math.abs(b.vx)>>1);}if(b.y>5500-r){b.y=5500-r;b.vy=0;}}
 // Stable pair order and integer corrections make browser/server replay identical.
 for(let pass=0;pass<4;pass++){
  for(let i=0;i<s.balls.length;i++){for(let j=i+1;j<s.balls.length;j++){
   const a=s.balls[i],b=s.balls[j],dx=b.x-a.x,dy=b.y-a.y,rr=RADIUS[a.level]+RADIUS[b.level];
   if(dx*dx+dy*dy>=rr*rr){continue;}
   if(a.level===b.level&&a.level<10){a.level++;a.x=Math.round((a.x+b.x)/2);a.y=Math.round((a.y+b.y)/2);a.vx=0;a.vy=0;s.score+=2**a.level*10;s.balls.splice(j,1);j--;continue;}
   const dist=Math.max(1,Math.floor(Math.sqrt(dx*dx+dy*dy))),overlap=rr-dist;
   const ox=dx===0&&dy===0?Math.ceil(overlap/2):Math.round(dx*overlap/dist/2),oy=dx===0&&dy===0?0:Math.round(dy*overlap/dist/2);
   a.x-=ox;b.x+=ox;a.y-=oy;b.y+=oy;a.vy=Math.min(a.vy,0);b.vy=Math.min(b.vy,0);
   for(const ball of [a,b]){const r=RADIUS[ball.level];ball.x=Math.max(r,Math.min(4000-r,ball.x));ball.y=Math.min(5500-r,ball.y);}
  }}
 }
 s.danger=s.balls.some(b=>b.y-RADIUS[b.level]<400)?s.danger+1:0;
 if(s.danger>180||s.balls.length>=70){s.over=true;}
}
function step(s,keys=[]) {
 if(s.over){return s;}
 if(s.q.length<4){throw new Error("queue_empty");}
 s.tick++;
 const has=(k)=>keys.includes(k), left=has('l'),right=has('r');
 if(s.game==='2048'){const dir=keys.find(k=>['l','r','u','d'].includes(k));if(dir){slide(s,dir);}}
 if(s.game==='blocks'){
  if(left||right){const p={...s.piece,x:s.piece.x+(left?-1:1)};if(fits(s,p)){s.piece=p;}}
  if(has('u')){const p={...s.piece,cells:s.piece.cells.map(([x,y])=>[-y,x])};const minX=Math.min(...p.cells.map(c=>c[0])),minY=Math.min(...p.cells.map(c=>c[1]));p.cells=p.cells.map(([x,y])=>[x-minX,y-minY]);if(fits(s,p)){s.piece=p;}}
  if(has('drop')){for(let i=0;i<21;i++){if(!lower(s)){break;}}}else if(has('d')||s.tick%Math.max(8,35-Math.floor(s.lines/5))===0){lower(s);}
 }
 if(s.game==='snake'){
  const dir=keys.map(k=>['u','r','d','l'].indexOf(k)).find(d=>d>=0);if(dir!==undefined&&(dir+2)%4!==s.dir&&!s.turned){s.dir=dir;s.turned=true;}
  if(s.tick%7===0){s.turned=false;const h=s.snake[0],x=h%20,y=Math.floor(h/20),nx=x+[0,1,0,-1][s.dir],ny=y+[-1,0,1,0][s.dir],n=ny*20+nx,eat=n===s.food;
   if(nx<0||nx>=20||ny<0||ny>=20||s.walls.includes(n)||s.snake.slice(0,eat?undefined:-1).includes(n)){s.over=true;}else{s.snake.unshift(n);if(eat){s.score+=100;food(s);}else{s.snake.pop();}}
  }
 }
 if(s.game==='bird'){
  if(has('tap')||has('u')){s.vy=-65;}s.vy+=3;s.y+=s.vy;
  if(s.tick>=s.next){s.pipes.push({x:4200,gap:1300+take(s,2700),passed:false});s.next=s.tick+120;}
  for(const p of s.pipes){p.x-=25;if(!p.passed&&p.x+400<900){p.passed=true;s.score++;}if(p.x<1050&&p.x+400>750&&(s.y-120<p.gap-750||s.y+120>p.gap+750)){s.over=true;}}
  s.pipes=s.pipes.filter(p=>p.x>-500);if(s.y<120||s.y>5480){s.over=true;}
 }
 if(s.game==='hex'){
  if(left){s.rotation=(s.rotation+5)%6;}if(right){s.rotation=(s.rotation+1)%6;}
  if(!s.falling){s.falling={lane:take(s,6),color:take(s,4)+1,distance:1900};}
  s.falling.distance-=12+Math.min(20,Math.floor(s.score/300));
  const lane=(s.falling.lane-s.rotation+6)%6,stack=s.lanes[lane];
  if(s.falling.distance<=stack.length*160){stack.push(s.falling.color);s.falling=null;const n=stack.length;if(n>=3&&stack[n-1]===stack[n-2]&&stack[n-2]===stack[n-3]){stack.splice(n-3,3);s.score+=100;}if(stack.length>=10){s.over=true;}}
 }
 if(s.game==='bricks'){
  if(left){s.paddle-=65;}if(right){s.paddle+=65;}s.paddle=Math.max(450,Math.min(3550,s.paddle));const px=s.x,py=s.y;s.x+=s.vx;s.y+=s.vy;
  if(s.x<60||s.x>3940){s.x=Math.max(60,Math.min(3940,s.x));s.vx=-s.vx;}if(s.y<60){s.y=60;s.vy=Math.abs(s.vy);}
  if(s.vy>0&&py<=5020&&s.y>=5020&&Math.abs(s.x-s.paddle)<=500){s.y=5020;s.vy=-36;s.vx=Math.round((s.x-s.paddle)/14)||12;}
  for(let i=0;i<48;i++){if(!s.board[i]){continue;}const x=100+(i%8)*475,y=600+Math.floor(i/8)*220;if(s.x+60>=x&&s.x-60<=x+435&&s.y+60>=y&&s.y-60<=y+180){s.board[i]=0;s.score+=100;if(px+60<x||px-60>x+435){s.vx=-s.vx;}else{s.vy=-s.vy;}break;}}
  if(s.y>5600){s.lives--;if(!s.lives){s.over=true;}else{s.x=s.paddle;s.y=4700;s.vx=27;s.vy=-36;}}if(!s.board.some(Boolean)){s.over=true;}
 }
 if(s.game==='merge'){
  if(left){s.aim-=80;}if(right){s.aim+=80;}
  const aim=keys.find(k=>k.startsWith('x:'));if(aim){s.aim=Number(aim.slice(2));}s.aim=Math.max(500,Math.min(3500,s.aim));
  if(s.cooldown>0){s.cooldown--;}
  if((has('drop')||has('tap'))&&!s.cooldown&&s.drops<100){s.balls.push({id:s.serial++,x:s.aim,y:650,level:s.next,vx:0,vy:0});s.next=take(s,4);s.drops++;s.cooldown=45;}
  mergePhysics(s);if(s.drops>=100&&!s.cooldown){s.over=true;}
 }
 if(s.tick>=s.limit){s.over=true;}return s;
}
function advance(state,frames,events){
 if(!Number.isInteger(frames)||frames<0||frames>180||!Array.isArray(events)||events.length>360){throw new Error('invalid_actions');}
 const s=clone(state), grouped={};let previous=-1;
 for(const e of events){if(!Array.isArray(e)||e.length!==2||!Number.isInteger(e[0])||e[0]<0||e[0]>=frames||e[0]<previous||typeof e[1]!=='string'||!(/^(l|r|u|d|drop|tap|x:[0-9]{1,4})$/).test(e[1])){throw new Error('invalid_actions');}previous=e[0];(grouped[e[0]]||= []).push(e[1]);if(grouped[e[0]].length>2){throw new Error('invalid_actions');}}
 if(s.game==='2048'&&(frames>1||events.length>1)){throw new Error('invalid_actions');}
 for(let i=0;i<frames;i++){if(s.over){throw new Error('already_over');}step(s,grouped[i]||[]);}return s;
}
function preview(state,dir){const s=clone(state);slide(s,dir,false);s.tick++;return s;}
const ArcadeCore={preview,version:ARCADE_VERSION,games:GAME_IDS,limits:LIMITS,radii:RADIUS,create,step,advance};
return ArcadeCore;

})();
const Playback=(()=>{


// One immutable request in flight, plus a bounded, locally simulated tail.
// The server remains authoritative. Refills are appended to the same random
// prefix, so replaying the tail on an acknowledgement never changes its draws.
class ArcadePlayback {
  constructor(run) {
    this.run = run;
    this.state = Core.advance(run.state, 0, []);
    this.frames = 0;
    this.events = [];
    this.keys = [];
    this.held = new Map();
    this.pending = null;
  }

  get grid() { return this.run.game === "2048"; }
  get blocked() {
    return this.grid ? !!this.pending || this.frames > 0 : this.frames >= 180 || this.state.q.length < 4;
  }
  get needsSync() {
    return this.frames > 0 && (this.grid || this.frames >= 120 || this.state.over || this.state.q.length < 8);
  }

  input(key) {
    if (this.state.over || this.run.status !== "playing") { return; }
    if ((this.grid || this.run.game === "snake") && !["l", "r", "u", "d"].includes(key)) { return; }
    if (key.startsWith("x:")) {
      this.keys = this.keys.filter(k => !k.startsWith("x:"));
    }
    // A pending fruit drop is enough; don't build up unintended future drops.
    if (this.run.game === "merge" && key === "drop" && this.keys.includes(key)) { return; }
    if (this.keys.length < 64) { this.keys.push(key); }
  }

  hold(key) {
    const game = this.run.game;
    if ((["blocks", "bricks", "hex", "merge"].includes(game) && ["l", "r"].includes(key)) ||
        (game === "blocks" && key === "d")) {
      if (!this.held.has(key)) { this.held.set(key, 0); }
    }
  }
  release(key) { key ? this.held.delete(key) : this.held.clear(); }

  advance() {
    if (this.blocked || this.state.over || this.run.status !== "playing") { return false; }
    if (this.grid) {
      const key = this.keys.shift();
      if (!key) { return false; }
      this.visualMove = {direction:key,board:this.state.board.slice(),tick:this.state.tick+1};
      this.state = Core.preview(this.state, key);
      this.events = [[0, key]];
      this.frames = 1;
      return true;
    }
    const keys = [];
    // Consume at most two distinct inputs per frame. Preserve the rest instead
    // of dropping rapid taps or a snake's second turn before it moves a cell.
    this.keys = this.keys.filter(key => {
      if (keys.length >= 2 || keys.includes(key)) { return true; }
      if (this.run.game === "snake" && (this.state.turned || keys.length)) { return true; }
      if (this.run.game === "merge" && key === "drop" && this.state.cooldown > 0) { return true; }
      keys.push(key);
      return false;
    });
    for (const [key, age] of this.held) {
      const continuous = this.run.game === "bricks" || (this.run.game === "blocks" && key === "d");
      if ((continuous || (age >= 12 && (age - 12) % 4 === 0)) && keys.length < 2 && !keys.includes(key)) {
        keys.push(key);
      }
      this.held.set(key, age + 1);
    }
    Core.step(this.state, keys);
    keys.forEach(key => this.events.push([this.frames, key]));
    this.frames++;
    return true;
  }

  checkpoint(requestId, finish = false) {
    if (this.pending) { return this.pending; }
    if (!this.frames && !finish) { return null; }
    this.pending = {
      version: this.run.version, request_id: requestId,
      frames: this.frames, events: this.events, finish,
    };
    this.frames = 0;
    this.events = [];
    return this.pending;
  }

  acknowledge(run) {
    if (!this.pending || run.id !== this.run.id || run.version !== this.pending.version + 1) {
      throw new Error("进度版本发生变化，请读取已保存进度。");
    }
    const state = Core.advance(run.state, this.frames, this.events);
    this.run = run;
    this.state = state;
    this.pending = null;
    if (run.status !== "playing") { this.keys = []; this.release(); }
  }
}

return ArcadePlayback;
})();
const Effects=(()=>{
// Presentation only. These snapshots never enter gameplay or score verification.
function tileTracks(board, direction) {
  const tracks=[];
  for(let lane=0;lane<4;lane++){
    const cells=Array.from({length:4},(_,i)=>direction==='l'?lane*4+i:direction==='r'?lane*4+3-i:direction==='u'?i*4+lane:(3-i)*4+lane);
    const occupied=cells.filter(i=>board[i]);let target=0;
    for(let i=0;i<occupied.length;i++){
      const from=occupied[i],to=cells[target++],merged=i+1<occupied.length&&board[from]===board[occupied[i+1]];
      tracks.push({from,to,value:board[from],merged});
      if(merged){tracks.push({from:occupied[++i],to,value:board[from],merged});}
    }
  }
  return tracks;
}
class ArcadeEffects {
  constructor({reducedMotion=false}={}) {
    this.reducedMotion=reducedMotion;this.previous=null;this.bursts=[];this.pops=new Map();this.trail=[];this.motion=null;this.turn=null;this.snakeMove=null;this.lastMove=null;this.scoreGain=null;
  }
  burst(x,y,color,now,radius=12){
    if(!this.reducedMotion){this.bursts.push({x,y,color,start:now,radius});this.bursts=this.bursts.slice(-16);}
  }
  observe(s,move=null,now=performance.now()) {
    const p=this.previous;
    if(p&&s.tick<p.tick){this.previous=null;this.motion=null;this.trail=[];this.bursts=[];this.pops.clear();this.lastMove=null;}
    const before=this.previous;
    if(move&&move!==this.lastMove&&s.game==='2048'){
      this.lastMove=move;
      this.motion={start:now,tracks:tileTracks(move.board,move.direction),board:move.board};
      for(const t of this.motion.tracks){if(t.merged){this.pops.set(t.to,now+110);}}
    }
    if(before){
      if(s.score>before.score){this.scoreGain={amount:s.score-before.score,start:now};}
      if(s.game==='2048'&&s.tick===before.tick){
        s.board.forEach((v,i)=>{if(v&&!before.board[i]){this.pops.set(i,now);}});
      }
      if(s.game==='blocks'&&s.lines>before.lines){
        const full=before.board.slice();before.piece?.cells.forEach(([x,y])=>{const i=(y+before.piece.y)*10+x+before.piece.x;if(i>=0&&i<200){full[i]=1;}});
        for(let row=0;row<20;row++){if(full.slice(row*10,row*10+10).every(Boolean)){for(let x=0;x<5;x++)this.burst(88+x*56,row*28+14,'#c3f0d7',now,22);}}
      }
      if(s.game==='snake'&&s.snake[0]!==before.snake[0]){
        this.snakeMove={from:before.snake,start:now};
        if(s.snake.length>before.snake.length){this.burst(before.food%20*20+10,Math.floor(before.food/20)*20+10,'#ffb5aa',now,18);}
      }
      if(s.game==='hex'&&s.rotation!==before.rotation){
        let delta=s.rotation-before.rotation;if(delta>3)delta-=6;if(delta<-3)delta+=6;
        this.turn={from:before.rotation,to:before.rotation+delta,start:now};
      }
      if(s.game==='hex'&&s.score>before.score){
        s.lanes.forEach((lane,i)=>{if(lane.length<before.lanes[i].length){const a=(i+s.rotation)*Math.PI/3,d=52+lane.length*16;this.burst(200+Math.cos(a)*d,280+Math.sin(a)*d,'#eddc99',now,25);}});
      }
      if(s.game==='bricks'){
        if(s.tick!==before.tick){this.trail.push({x:s.x/10,y:s.y/10});this.trail=this.trail.slice(-8);}
        before.board.forEach((v,i)=>{if(v&&!s.board[i])this.burst(31.75+i%8*47.5,69+Math.floor(i/8)*22,'#e9d578',now,16);});
        if(s.lives<before.lives){this.burst(s.paddle/10,510,'#f389a2',now,35);this.trail=[];}
      }
      if(s.game==='merge'&&s.score>before.score){
        const old=new Set(before.balls.map(b=>b.id));
        s.balls.forEach(b=>{if(!old.has(b.id)){this.burst(b.x/10,b.y/10,'#f6df9c',now,18+b.level*3);this.pops.set(b.id,now);}});
      }
    }
    this.previous={game:s.game,tick:s.tick,score:s.score,lines:s.lines,food:s.food,rotation:s.rotation,lives:s.lives,
      board:s.board?.slice(),piece:s.piece?{...s.piece}:null,snake:s.snake?.slice(),lanes:s.lanes?.map(l=>l.slice()),balls:s.balls?.map(b=>({id:b.id}))};
    for(const [key,start] of this.pops){if(now-start>500)this.pops.delete(key);}
    this.bursts=this.bursts.filter(b=>now-b.start<500);
  }
  active(now=performance.now()){
    if(this.reducedMotion)return false;
    return (this.motion&&now-this.motion.start<110)||(this.turn&&now-this.turn.start<100)||
      (this.snakeMove&&now-this.snakeMove.start<85)||(this.scoreGain&&now-this.scoreGain.start<650)||
      this.bursts.some(b=>now-b.start<500)||[...this.pops.values()].some(t=>now-t<350);
  }
  pop(key,now){
    if(this.reducedMotion)return 1;
    const start=this.pops.get(key),t=(now-start)/240;
    return start!==undefined&&t>=0&&t<1?1+Math.sin(t*Math.PI)*.12:1;
  }
  rotation(s,now){
    if(!this.turn||this.reducedMotion)return s.rotation;
    const t=Math.min(1,Math.max(0,(now-this.turn.start)/100));return this.turn.from+(this.turn.to-this.turn.from)*(1-(1-t)**3);
  }
  overlay(ctx,now){
    if(this.reducedMotion)return;
    for(const b of this.bursts){const t=(now-b.start)/500;if(t<0||t>1)continue;ctx.save();ctx.globalAlpha=1-t;ctx.strokeStyle=b.color;ctx.lineWidth=2;ctx.beginPath();ctx.arc(b.x,b.y,b.radius*(.5+t),0,Math.PI*2);ctx.stroke();
      ctx.fillStyle=b.color;for(let i=0;i<8;i++){const a=i*Math.PI/4,d=b.radius*t*2.3;ctx.fillRect(b.x+Math.cos(a)*d-1.5,b.y+Math.sin(a)*d-1.5,3,3);}ctx.restore();}
    const gain=this.scoreGain;if(gain){const t=(now-gain.start)/650;if(t>=0&&t<1){ctx.save();ctx.globalAlpha=1-t;ctx.fillStyle='#e5f6c6';ctx.font='700 22px system-ui';ctx.textAlign='center';ctx.fillText(`+${gain.amount}`,200,36-t*18);ctx.restore();}}
  }
}

return ArcadeEffects;
})();
const draw=(()=>{

const PALETTE=['#84ddc0','#f6bf70','#9b9ef1','#f389a2','#6dc9e8','#e9d578','#ba9dea'];
function draw(canvas,s,fx=null,now=performance.now()) {
 const ctx=canvas.getContext('2d');if(!ctx){return;}const width=400,height=s.game==='2048'||s.game==='snake'?400:560;
 const scale=Math.min(window.devicePixelRatio||1,2);if(canvas.width!==width*scale||canvas.height!==height*scale){canvas.width=width*scale;canvas.height=height*scale;canvas.style.aspectRatio=`${width}/${height}`;}
 ctx.setTransform(scale,0,0,scale,0,0);ctx.fillStyle='#102c39';ctx.fillRect(0,0,width,height);
 const box=(x,y,w,h,color,r=6)=>{ctx.fillStyle=color;ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fill();};
 const text=(v,x,y,size=24,color='#effaf8')=>{ctx.fillStyle=color;ctx.font=`700 ${size}px system-ui`;ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillText(String(v),x,y);};
 if(s.game==='2048'){
  const tile=(v,i,scale=1,x=null,y=null)=>{x=x??12+i%4*97;y=y??12+Math.floor(i/4)*97;ctx.save();ctx.translate(x+42.5,y+42.5);ctx.scale(scale,scale);box(-42.5,-42.5,85,85,PALETTE[(Math.log2(v)-1)%7],12);text(v,0,0,v>=10000?21:29,'#13323b');ctx.restore();};
  for(let i=0;i<16;i++)box(12+i%4*97,12+Math.floor(i/4)*97,85,85,'#203e4c',12);
  const m=fx?.motion,t=m?Math.min(1,Math.max(0,(now-m.start)/110)):1;
  if(m&&t<1&&!fx.reducedMotion){const ease=1-(1-t)**3;m.tracks.forEach(track=>{const x=12+(track.from%4+(track.to%4-track.from%4)*ease)*97,y=12+(Math.floor(track.from/4)+(Math.floor(track.to/4)-Math.floor(track.from/4))*ease)*97;tile(track.value,track.to,1,x,y);});}
  else{s.board.forEach((v,i)=>{if(v)tile(v,i,fx?.pop(i,now)||1);});}
 }
 if(s.game==='blocks'){
  const cell=(i,v)=>{if(v){box(60+i%10*28,Math.floor(i/10)*28,26,26,PALETTE[(v-1)%7],4);}};
  ctx.strokeStyle='#23424f';for(let x=60;x<=340;x+=28){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,560);ctx.stroke();}
  s.board.forEach((v,i)=>cell(i,v));if(s.piece){
   let ghost=s.piece.y;
   const fits=y=>s.piece.cells.every(([x,dy])=>{x+=s.piece.x;dy+=y;return x>=0&&x<10&&dy>=0&&dy<20&&!s.board[dy*10+x];});
   while(fits(ghost+1))ghost++;
   ctx.save();ctx.globalAlpha=.24;s.piece.cells.forEach(([x,y])=>cell((y+ghost)*10+x+s.piece.x,s.piece.color));ctx.restore();
   s.piece.cells.forEach(([x,y])=>cell((y+s.piece.y)*10+x+s.piece.x,s.piece.color));
  }
 }
 if(s.game==='snake'){
  s.walls.forEach(i=>box(i%20*20+1,Math.floor(i/20)*20+1,18,18,'#526775',3));
  const movement=fx?.snakeMove,t=movement&&!fx.reducedMotion?Math.min(1,Math.max(0,(now-movement.start)/85)):1;
  s.snake.forEach((i,k)=>{const old=movement?.from[Math.min(k,movement.from.length-1)]??i;const x=(old%20+(i%20-old%20)*t)*20,y=(Math.floor(old/20)+(Math.floor(i/20)-Math.floor(old/20))*t)*20;box(x+1,y+1,18,18,k?'#6ed3ac':'#d5f89b',5);if(!k){const dx=[0,1,0,-1][s.dir],dy=[-1,0,1,0][s.dir];ctx.fillStyle='#163d36';for(const side of [-1,1]){ctx.beginPath();ctx.arc(x+10+dx*5+dy*side*4,y+10+dy*5-dx*side*4,1.7,0,7);ctx.fill();}}});
  box(s.food%20*20+3,Math.floor(s.food/20)*20+3,14,14,'#ff9e9f',7);
 }
 if(s.game==='bird'){
  ctx.fillStyle='#1d4351';for(let i=0;i<8;i++){ctx.beginPath();ctx.arc((i*71-s.tick/3)%470,80+i%3*130,24,0,7);ctx.fill();}
  s.pipes.forEach(p=>{box(p.x/10,0,40,(p.gap-750)/10,'#70c9ad',4);box(p.x/10,(p.gap+750)/10,40,560-(p.gap+750)/10,'#70c9ad',4);});
  ctx.save();ctx.translate(90,s.y/10);ctx.rotate(Math.max(-.4,Math.min(.7,s.vy/120)));box(-15,-12,30,24,'#f8d17f',10);ctx.fillStyle='#173849';ctx.beginPath();ctx.arc(8,-4,3,0,7);ctx.fill();ctx.save();ctx.translate(-7,3);ctx.rotate(fx?.reducedMotion?0:Math.sin(s.tick*.8)*.55);box(-8,-2,16,8,'#f3a872',5);ctx.restore();ctx.fillStyle='#f0a45d';ctx.beginPath();ctx.moveTo(13,-1);ctx.lineTo(23,3);ctx.lineTo(13,6);ctx.fill();ctx.restore();
 }
 if(s.game==='hex'){
  const cx=200,cy=280,hex=(radius)=>{ctx.beginPath();for(let i=0;i<6;i++){const a=i*Math.PI/3;ctx.lineTo(cx+Math.cos(a)*radius,cy+Math.sin(a)*radius);}ctx.closePath();};
  const rotation=fx?.rotation(s,now)??s.rotation;ctx.save();ctx.translate(cx,cy);ctx.rotate(rotation*Math.PI/3);ctx.translate(-cx,-cy);hex(43);ctx.fillStyle='#94d7c1';ctx.fill();ctx.restore();text('⬡',cx,cy,35,'#173849');
  const block=(lane,dist,color)=>{const a=lane*Math.PI/3;ctx.save();ctx.translate(cx+Math.cos(a)*dist,cy+Math.sin(a)*dist);ctx.rotate(a);box(-7,-19,14,38,PALETTE[color-1],3);ctx.restore();};
  s.lanes.forEach((lane,i)=>lane.forEach((c,j)=>block((i+rotation)%6,52+j*16,c)));
  if(s.falling){block(s.falling.lane,52+s.falling.distance/10,s.falling.color);}
 }
 if(s.game==='bricks'){
  s.board.forEach((v,i)=>{if(v){box(10+i%8*47.5,60+Math.floor(i/8)*22,43.5,18,PALETTE[Math.floor(i/8)],4);}});
  if(fx&&!fx.reducedMotion){fx.trail.forEach((point,i)=>{ctx.save();ctx.globalAlpha=(i+1)/fx.trail.length*.22;ctx.fillStyle='#fff0ba';ctx.beginPath();ctx.arc(point.x,point.y,2+i*.4,0,7);ctx.fill();ctx.restore();});}
  box(s.paddle/10-45,508,90,10,'#b3ead8',5);ctx.beginPath();ctx.arc(s.x/10,s.y/10,6,0,7);ctx.fillStyle='#fff0ba';ctx.fill();text('●'.repeat(s.lives),200,540,15,'#91c9be');
 }
 if(s.game==='merge'){
  ctx.strokeStyle=s.danger?'#ff8497':'#496774';ctx.setLineDash([5,6]);ctx.beginPath();ctx.moveTo(8,40);ctx.lineTo(392,40);ctx.stroke();ctx.setLineDash([]);
  const fruit=(x,y,level,ghost=false,pop=1)=>{const r=Core.radii[level]/10*pop,img=fx?.sprites?.[level];ctx.save();ctx.globalAlpha=ghost?.7:1;ctx.beginPath();ctx.arc(x,y,r,0,7);if(img?.complete&&img.naturalWidth){ctx.clip();ctx.imageSmoothingEnabled=true;ctx.imageSmoothingQuality='high';ctx.drawImage(img,x-r,y-r,r*2,r*2);}else{ctx.fillStyle=PALETTE[level%7];ctx.fill();text(level+1,x,y,r);}ctx.restore();};
  if(s.drops<100){const aim=s.aim/10;const first=s.balls.filter(b=>Math.abs(b.x-s.aim)<Core.radii[b.level]).reduce((v,b)=>Math.min(v,(b.y-Core.radii[b.level])/10),550);ctx.save();ctx.strokeStyle='#8bb5ad66';ctx.setLineDash([3,7]);ctx.beginPath();ctx.moveTo(aim,50);ctx.lineTo(aim,Math.max(50,first));ctx.stroke();ctx.restore();}
  s.balls.forEach(b=>fruit(b.x/10,b.y/10,b.level,false,fx?.pop(b.id,now)||1));if(s.drops<100){fruit(s.aim/10,25,s.next,true);if(s.cooldown){box(s.aim/10-18,48,36*(1-s.cooldown/45),2,'#b3ead8',1);}}

 }
 fx?.overlay(ctx,now);
}

return draw;
})();
// Original merge_qshp artwork, preserved byte-for-byte. See public/arcade/merge/source.json.
const mergeSpriteFiles = Object.freeze(["00-973df787c094.png", "01-22a658c02581.png", "02-690977014d67.png", "03-3f62e392f2c9.png", "04-799a4a503725.png", "05-977c9c41d76b.png", "06-906829a14b81.png", "07-544ca786e264.png", "08-336ebbcf460a.png", "09-bb68a2bb9cd6.png", "10-bce7f4a63be4.png"]);
const loads=new Map();
function loadMergeSprites(base='/plugins/discourse-rsc/arcade/merge/'){
 if(!loads.has(base)){
  loads.set(base,Promise.all(mergeSpriteFiles.map(file=>new Promise(resolve=>{
   const img=new Image();img.decoding='async';img.onload=()=>resolve(img);img.onerror=()=>resolve(null);img.src=base+file;
  }))).then(images=>{if(images.some(img=>!img)){loads.delete(base);}return images;}));
 }
 return loads.get(base);
}

globalThis.RiversideArcade=Object.freeze({protocol:1,rulesVersion:Core.version,Core,Playback,Effects,draw,loadMergeSprites,mergeSpriteFiles});
})();
