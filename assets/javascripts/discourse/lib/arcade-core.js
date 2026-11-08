// Shared deterministic rules. No clock, browser API, random seed or wallet access.
// All coordinates and velocities are integers. Rendering never affects simulation.
const ARCADE_VERSION = 3;
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
function lower(s) {const p={...s.piece,y:s.piece.y+1};if(fits(s,p)){s.piece=p;return true;}for(const [x,y] of s.piece.cells){s.board[(s.piece.y+y)*10+s.piece.x+x]=s.piece.color;}let lines=0;for(let y=19;y>=0;y--){if(s.board.slice(y*10,y*10+10).every(Boolean)){s.board.splice(y*10,10);s.board.unshift(...Array(10).fill(0));lines++;y++;}}s.lines+=lines;s.score+=[0,100,300,500,800][lines];if(s.version===1&&s.pieces>=200){s.over=true;}else{block(s);}return false;}
function create(game,q,version=ARCADE_VERSION) {
 if(![1,2,3].includes(version)){throw new Error("rules_version");}
 if(!GAME_IDS.includes(game)){throw new Error("game");}
 const s={game,version,tick:0,score:0,over:false,q:q.slice(),limit:version===1?LIMITS[game]:null};
 if(game==="2048"){s.board=Array(16).fill(0);tile(s);tile(s);}
 if(game==="blocks"){s.board=Array(200).fill(0);s.lines=0;s.pieces=0;block(s);}
 if(game==="snake"){s.snake=[210,209,208];s.dir=1;s.walls=[84,85,86,87,312,313,314,315];food(s);}
 if(game==="bird"){s.y=2500;s.vy=0;s.pipes=[];s.next=0;}
 if(game==="hex"){s.lanes=Array.from({length:6},()=>[]);s.rotation=0;s.falling=null;}
 if(game==="bricks"){s.x=2000;s.y=4700;s.vx=27;s.vy=-36;s.paddle=2000;s.lives=3;s.board=Array(48).fill(1);if(version>=2){s.wave=1;}}
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
function nextWave(s) {
 s.wave=(s.wave||1)+1;
 s.board=Array.from({length:48},(_,i)=>{
  const row=Math.floor(i/8),col=i%8;
  const gap=s.wave%3===2?(row+col)%7===0:s.wave%3===0?row%2===1&&col%3===1:false;
  return gap?0:Math.min(3,1+Math.floor((s.wave-1)/3)+(row<2?0:-1))||1;
 });
 s.x=s.paddle;s.y=4700;s.vx=27;s.vy=-Math.min(65,36+(s.wave-1)*3);
 delete s.target;
}
function mergePhysicsV2(s) {
 // Integer, fixed substeps: identical on the client and server. Resolve actual
 // penetration/normal velocity, rather than cancelling every vertical velocity.
 const merged=new Set();
 for(let sub=0;sub<2;sub++){
  for(const b of s.balls){b.vy=Math.min(110,b.vy+2);b.x+=Math.round(b.vx/2);b.y+=Math.round(b.vy/2);b.vx=Math.trunc(b.vx*995/1000);}
  for(let pass=0;pass<3;pass++){
   // Spatial buckets avoid scanning every possible pair in a long session.
   const buckets=new Map(),pairs=new Set();
   for(let i=0;i<s.balls.length;i++){
    const b=s.balls[i],r=RADIUS[b.level];
    for(let x=Math.floor((b.x-r)/500);x<=Math.floor((b.x+r)/500);x++)for(let y=Math.floor((b.y-r)/500);y<=Math.floor((b.y+r)/500);y++){
     const key=x+','+y,ids=buckets.get(key)||[];
     for(const j of ids)pairs.add(j*s.balls.length+i);
     ids.push(i);buckets.set(key,ids);
    }
   }
   const removed=new Set();
   for(const code of [...pairs].sort((a,b)=>a-b)){
    const i=Math.floor(code/s.balls.length),j=code%s.balls.length;
    if(removed.has(i)||removed.has(j))continue;
    const a=s.balls[i],b=s.balls[j],ra=RADIUS[a.level],rb=RADIUS[b.level],dx=b.x-a.x,dy=b.y-a.y,rr=ra+rb;
    if(dx*dx+dy*dy>=rr*rr)continue;
    if(a.level===b.level&&a.level<10&&!merged.has(a.id)&&!merged.has(b.id)){
     a.level++;a.x=Math.round((a.x+b.x)/2);a.y=Math.round((a.y+b.y)/2);a.vx=Math.round((a.vx+b.vx)/2);a.vy=Math.round((a.vy+b.vy)/2);
     s.score+=2**a.level*10;removed.add(j);merged.add(a.id);continue;
    }
    const dist=Math.max(1,Math.floor(Math.sqrt(dx*dx+dy*dy))),nx=dx===0&&dy===0?1000:Math.round(dx*1000/dist),ny=Math.round(dy*1000/dist);
    const overlap=rr-dist,wa=rb*rb/(ra*ra+rb*rb),wb=1-wa;
    a.x-=Math.round(nx*overlap*wa/1000);a.y-=Math.round(ny*overlap*wa/1000);
    b.x+=Math.round(nx*overlap*wb/1000);b.y+=Math.round(ny*overlap*wb/1000);
    const approach=Math.round(((b.vx-a.vx)*nx+(b.vy-a.vy)*ny)/1000);
    if(approach<0){a.vx+=Math.round(approach*nx*wa/1000);a.vy+=Math.round(approach*ny*wa/1000);b.vx-=Math.round(approach*nx*wb/1000);b.vy-=Math.round(approach*ny*wb/1000);}
   }
   s.balls=s.balls.filter((_,i)=>!removed.has(i));
   for(const b of s.balls){const r=RADIUS[b.level];if(b.x<r){b.x=r;b.vx=Math.max(0,Math.round(-b.vx/5));}if(b.x>4000-r){b.x=4000-r;b.vx=Math.min(0,Math.round(-b.vx/5));}if(b.y>5500-r){b.y=5500-r;b.vy=0;b.vx=Math.trunc(b.vx*9/10);}}
  }
 }
 for(const b of s.balls){b.vx=b.vx||0;b.vy=b.vy||0;b.x=b.x||0;b.y=b.y||0;}
 s.danger=s.balls.some(b=>b.y-RADIUS[b.level]<400)?s.danger+1:0;
 if(s.danger>180)s.over=true;
}
// Version 3 keeps rotational momentum. Fixed substeps, stable pair order and
// quantized state are shared by browser and server (not render-frame dependent).
function mergePhysicsV3(s) {
 const merged=new Set(),clamp=(v,n)=>Math.max(-n,Math.min(n,v));
 for(let sub=0;sub<2;sub++){
  for(const b of s.balls){
   b.spin=b.spin||0;b.angle=b.angle||0;
   b.vy=Math.min(140,b.vy+2);b.x+=Math.round(b.vx/2);b.y+=Math.round(b.vy/2);
   b.angle=(b.angle+Math.round(b.spin/2)+62832)%62832;
   b.spin=Math.round(b.spin*998/1000);
  }
  for(let pass=0;pass<4;pass++){
   const buckets=new Map(),pairs=new Set(),count=s.balls.length;
   for(let i=0;i<count;i++){
    const b=s.balls[i],r=RADIUS[b.level];
    for(let x=Math.floor((b.x-r)/500);x<=Math.floor((b.x+r)/500);x++)for(let y=Math.floor((b.y-r)/500);y<=Math.floor((b.y+r)/500);y++){
     const key=x+','+y,ids=buckets.get(key)||[];
     for(const j of ids)pairs.add(j*count+i);
     ids.push(i);buckets.set(key,ids);
    }
   }
   const removed=new Set();
   for(const code of [...pairs].sort((a,b)=>a-b)){
    const i=Math.floor(code/count),j=code%count;if(removed.has(i)||removed.has(j))continue;
    const a=s.balls[i],b=s.balls[j],ra=RADIUS[a.level],rb=RADIUS[b.level],dx=b.x-a.x,dy=b.y-a.y,rr=ra+rb;
    if(dx*dx+dy*dy>rr*rr)continue;
    if(a.level===b.level&&a.level<10&&!merged.has(a.id)&&!merged.has(b.id)){
     a.level++;a.x=Math.round((a.x+b.x)/2);a.y=Math.round((a.y+b.y)/2);
     a.vx=Math.round((a.vx+b.vx)/2);a.vy=Math.round((a.vy+b.vy)/2);a.spin=Math.round((a.spin+b.spin)/2);
     s.score+=2**a.level*10;removed.add(j);merged.add(a.id);continue;
    }
    const dist=Math.max(1,Math.sqrt(dx*dx+dy*dy)),nx=dx===0&&dy===0?1:dx/dist,ny=dy/dist,tx=-ny,ty=nx;
    const wa=rb*rb/(ra*ra+rb*rb),wb=1-wa,overlap=Math.max(0,rr-dist-1)*.8;
    a.x-=Math.round(nx*overlap*wa);a.y-=Math.round(ny*overlap*wa);b.x+=Math.round(nx*overlap*wb);b.y+=Math.round(ny*overlap*wb);
    const normal=(b.vx-a.vx)*nx+(b.vy-a.vy)*ny;
    // Small impacts settle; harder impacts retain a little bounce.
    const impulse=normal<0?-normal*(normal < -16?1.12:1):0;
    a.vx-=Math.round(impulse*nx*wa);a.vy-=Math.round(impulse*ny*wa);b.vx+=Math.round(impulse*nx*wb);b.vy+=Math.round(impulse*ny*wb);
    const slip=(b.vx-a.vx)*tx+(b.vy-a.vy)*ty-(a.spin*ra+b.spin*rb)/10000;
    const tangent=clamp(-slip/3,.3*(impulse+2*Math.abs(ny)));
    a.vx-=Math.round(tangent*tx*wa);a.vy-=Math.round(tangent*ty*wa);b.vx+=Math.round(tangent*tx*wb);b.vy+=Math.round(tangent*ty*wb);
    a.spin-=Math.round(20000*tangent*wa/ra);b.spin-=Math.round(20000*tangent*wb/rb);
   }
   s.balls=s.balls.filter((_,i)=>!removed.has(i));
   for(const b of s.balls){
    const r=RADIUS[b.level];
    if(b.x<r||b.x>4000-r){
     const side=b.x<r?-1:1;b.x=Math.max(r,Math.min(4000-r,b.x));
     if(b.vx*side>0)b.vx=Math.round(-b.vx*.12);
     const slip=b.vy+side*b.spin*r/10000,friction=clamp(slip/3,2);
     b.vy-=Math.round(friction);b.spin-=Math.round(side*20000*friction/r);
    }
    if(b.y>=5500-r){
     b.y=5500-r;if(b.vy>0)b.vy=b.vy>16?Math.round(-b.vy*.12):0;
     const slip=b.vx-b.spin*r/10000,friction=clamp(slip/3,2);
     b.vx-=Math.round(friction);b.spin+=Math.round(20000*friction/r);
     // Rolling resistance is much weaker than sliding friction.
     if(pass===3){b.vx=Math.trunc(b.vx*.995);b.spin=Math.trunc(b.spin*.995);}
    }
    b.vx=clamp(b.vx,180);b.vy=clamp(b.vy,180);b.spin=clamp(b.spin,3000);
   }
  }
 }
 s.danger=s.balls.some(b=>b.y-RADIUS[b.level]<400)?s.danger+1:0;if(s.danger>180)s.over=true;
}
function birdHitsPipe(y,p) {
 // Body inset excludes beak/wing decoration; rounded corners allow near misses.
 const x=900,rx=110,ry=85,half=p.half||750;
 const nearestX=Math.max(p.x,Math.min(p.x+400,x));
 const dy=y<p.gap-half?0:y>p.gap+half?0:Math.min(y-(p.gap-half),p.gap+half-y);
 return ((x-nearestX)/rx)**2+(dy/ry)**2<1;
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
  if(has('drop')){for(let i=0;i<21;i++){if(!lower(s)){break;}}}else if(has('d')||s.tick%Math.max(s.version===1?8:5,35-Math.floor(s.lines/5))===0){lower(s);}
 }
 if(s.game==='snake'){
  const dir=keys.map(k=>['u','r','d','l'].indexOf(k)).find(d=>d>=0);if(dir!==undefined&&(dir+2)%4!==s.dir&&!s.turned){s.dir=dir;s.turned=true;}
  if(s.tick%7===0){s.turned=false;const h=s.snake[0],x=h%20,y=Math.floor(h/20),nx=x+[0,1,0,-1][s.dir],ny=y+[-1,0,1,0][s.dir],n=ny*20+nx,eat=n===s.food;
   if(nx<0||nx>=20||ny<0||ny>=20||s.walls.includes(n)||s.snake.slice(0,eat?undefined:-1).includes(n)){s.over=true;}else{s.snake.unshift(n);if(eat){s.score+=100;food(s);}else{s.snake.pop();}}
  }
 }
 if(s.game==='bird'){
  if(has('tap')||has('u')){s.vy=-65;}s.vy+=3;s.y+=s.vy;
  if(s.tick>=s.next){s.pipes.push({x:4200,gap:1300+take(s,2700),passed:false,...(s.version>=2?{half:Math.max(600,750-Math.floor(s.score/15)*15)}:{})});s.next=s.tick+120;}
  for(const p of s.pipes){p.x-=s.version===1?25:Math.min(40,25+Math.floor(s.score/20));if(!p.passed&&p.x+400<900){p.passed=true;s.score++;}if(s.version>=3?birdHitsPipe(s.y,p):(p.x<1050&&p.x+400>750&&(s.y-120<p.gap-(p.half||750)||s.y+120>p.gap+(p.half||750)))){s.over=true;}}
  s.pipes=s.pipes.filter(p=>p.x>-500);if(s.y<(s.version>=3?85:120)||s.y>(s.version>=3?5515:5480)){s.over=true;}
 }
 if(s.game==='hex'){
  if(left){s.rotation=(s.rotation+5)%6;}if(right){s.rotation=(s.rotation+1)%6;}
  if(!s.falling){s.falling={lane:take(s,6),color:take(s,4)+1,distance:1900};}
  s.falling.distance-=12+Math.min(s.version===1?20:28,Math.floor(s.score/300));
  const lane=(s.falling.lane-s.rotation+6)%6,stack=s.lanes[lane];
  if(s.falling.distance<=stack.length*160){stack.push(s.falling.color);s.falling=null;const n=stack.length;if(n>=3&&stack[n-1]===stack[n-2]&&stack[n-2]===stack[n-3]){stack.splice(n-3,3);s.score+=100;}if(stack.length>=10){s.over=true;}}
 }
 if(s.game==='bricks'){
  if(s.version>=2){const aim=keys.find(k=>k.startsWith('x:'));if(aim){s.target=Math.max(450,Math.min(3550,Number(aim.slice(2))));}if(left||right){delete s.target;}if(s.target!==undefined){s.paddle+=Math.max(-65,Math.min(65,s.target-s.paddle));}}
  if(left){s.paddle-=65;}if(right){s.paddle+=65;}s.paddle=Math.max(450,Math.min(3550,s.paddle));const px=s.x,py=s.y;s.x+=s.vx;s.y+=s.vy;
  if(s.x<60||s.x>3940){s.x=Math.max(60,Math.min(3940,s.x));s.vx=-s.vx;}if(s.y<60){s.y=60;s.vy=Math.abs(s.vy);}
  if(s.vy>0&&py<=5020&&s.y>=5020&&Math.abs(s.x-s.paddle)<=500){s.y=5020;s.vy=-(s.version===1?36:Math.min(65,36+((s.wave||1)-1)*3));s.vx=Math.round((s.x-s.paddle)/14)||12;}
  for(let i=0;i<48;i++){if(!s.board[i]){continue;}const x=100+(i%8)*475,y=600+Math.floor(i/8)*220;if(s.x+60>=x&&s.x-60<=x+435&&s.y+60>=y&&s.y-60<=y+180){s.board[i]--;if(!s.board[i]){s.score+=100;}if(px+60<x||px-60>x+435){s.vx=-s.vx;}else{s.vy=-s.vy;}break;}}
  if(s.y>5600){s.lives--;if(!s.lives){s.over=true;}else{s.x=s.paddle;s.y=4700;s.vx=27;s.vy=-36;}}if(!s.board.some(Boolean)){if(s.version===1){s.over=true;}else{nextWave(s);}}
 }
 if(s.game==='merge'){
  if(left){s.aim-=80;}if(right){s.aim+=80;}
  const aim=keys.find(k=>k.startsWith('x:'));if(aim){s.aim=Number(aim.slice(2));}const edge=s.version===1?500:RADIUS[s.next];s.aim=Math.max(edge,Math.min(4000-edge,s.aim));
  if(s.cooldown>0){s.cooldown--;}
  if((has('drop')||has('tap'))&&!s.cooldown&&(s.version>=2||s.drops<100)){s.balls.push({id:s.serial++,x:s.aim,y:650,level:s.next,vx:0,vy:s.version===1?0:24});s.next=take(s,4);s.drops++;s.cooldown=s.version===1?45:24;}
  if(s.version===1){mergePhysics(s);}else{if(s.version>=3){mergePhysicsV3(s);}else{mergePhysicsV2(s);}s.aim=Math.max(RADIUS[s.next],Math.min(4000-RADIUS[s.next],s.aim));}if(s.version===1&&s.drops>=100&&!s.cooldown){s.over=true;}
 }
 if(s.limit!==null&&s.tick>=s.limit){s.over=true;}return s;
}
function advance(state,frames,events){
 if(!Number.isInteger(frames)||frames<0||frames>180||!Array.isArray(events)||events.length>360){throw new Error('invalid_actions');}
 const s=clone(state), grouped={};let previous=-1;
 for(const e of events){if(!Array.isArray(e)||e.length!==2||!Number.isInteger(e[0])||e[0]<0||e[0]>=frames||e[0]<previous||typeof e[1]!=='string'||!(/^(l|r|u|d|drop|tap|x:[0-9]{1,4})$/).test(e[1])){throw new Error('invalid_actions');}previous=e[0];(grouped[e[0]]||= []).push(e[1]);if(grouped[e[0]].length>2){throw new Error('invalid_actions');}}
 if(s.game==='2048'&&(frames>16||Object.values(grouped).some(keys=>keys.length>1||!['l','r','u','d'].includes(keys[0])))){throw new Error('invalid_actions');}
 for(let i=0;i<frames;i++){if(s.over){throw new Error('already_over');}step(s,grouped[i]||[]);}return s;
}
function preview(state,dir){const s=clone(state);slide(s,dir,false);s.tick++;return s;}
const ArcadeCore={preview,version:ARCADE_VERSION,games:GAME_IDS,limits:LIMITS,radii:RADIUS,create,step,advance};
export default ArcadeCore;
