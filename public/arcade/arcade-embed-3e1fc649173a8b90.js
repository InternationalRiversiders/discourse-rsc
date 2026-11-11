/* Generated from the forum UI. Do not edit. */
(()=>{"use strict";
const Core=(()=>{
// Shared deterministic rules. No clock, browser API, random seed or wallet access.
// All coordinates and velocities are integers. Rendering never affects simulation.
const ARCADE_VERSION = 4;
const GAME_IDS = ["2048", "blocks", "snake", "bird", "hex", "bricks", "merge", "sudoku"];
const LIMITS = {"2048": 2000, blocks: 18000, snake: 18000, bird: 10800, hex: 10800, bricks: 18000, merge: 18000};
const SHAPES = [[[0,0],[1,0],[2,0],[3,0]],[[0,0],[1,0],[0,1],[1,1]],[[1,0],[0,1],[1,1],[2,1]],[[1,0],[2,0],[0,1],[1,1]],[[0,0],[1,0],[1,1],[2,1]],[[0,0],[0,1],[1,1],[2,1]],[[2,0],[0,1],[1,1],[2,1]]];
const RADIUS = [110,145,185,235,295,365,445,535,635,745,865];
const clone = (s) => JSON.parse(JSON.stringify(s));
function take(s,n) { if (!s.q.length) { throw new Error("queue_empty"); } return s.q.shift()%n; }
function tile(s) { const empty=s.board.map((v,i)=>v?null:i).filter(i=>i!==null); if(empty.length){s.board[empty[take(s,empty.length)]]=take(s,10)===0?4:2;} }
function food(s) { const free=[];for(let i=0;i<400;i++){if(!s.snake.includes(i)&&!s.walls.includes(i)){free.push(i);}}if(!free.length){s.over=true;}else{s.food=free[take(s,free.length)];} }
function block(s) {
 if(s.version>=4){
  if(!s.bag?.length)s.bag=[0,1,2,3,4,5,6];
  const shape=s.bag.splice(take(s,s.bag.length),1)[0];
  s.piece={cells:shape===0?[[0,1],[1,1],[2,1],[3,1]]:clone(SHAPES[shape]),shape,rotation:0,x:3,y:0,color:shape+1};
  s.pieces++;s.fall=0;s.lock=0;s.lockResets=0;if(!fits(s,s.piece))s.over=true;return;
 }
 s.piece={cells:clone(SHAPES[take(s,7)]),x:3,y:0,color:s.pieces%7+1};s.pieces++;if(!fits(s,s.piece)){s.over=true;} }
function fits(s,p) {return p.cells.every(([x,y])=>{x+=p.x;y+=p.y;return x>=0&&x<10&&y>=0&&y<20&&!s.board[y*10+x];});}
function lower(s) {const p={...s.piece,y:s.piece.y+1};if(fits(s,p)){s.piece=p;return true;}for(const [x,y] of s.piece.cells){s.board[(s.piece.y+y)*10+s.piece.x+x]=s.piece.color;}let lines=0;for(let y=19;y>=0;y--){if(s.board.slice(y*10,y*10+10).every(Boolean)){s.board.splice(y*10,10);s.board.unshift(...Array(10).fill(0));lines++;y++;}}s.lines+=lines;s.score+=[0,100,300,500,800][lines];if(s.version===1&&s.pieces>=200){s.over=true;}else{block(s);}return false;}
// Sudoku inputs are replayed against server-owned givens, never a client score.
const sudokuUnits = [...Array.from({length:9},(_,r)=>Array.from({length:9},(_,c)=>r*9+c)),...Array.from({length:9},(_,c)=>Array.from({length:9},(_,r)=>r*9+c)),...Array.from({length:9},(_,b)=>Array.from({length:9},(_,i)=>(Math.floor(b/3)*3+Math.floor(i/3))*9+b%3*3+i%3))];
const sudokuPeers=Array.from({length:81},(_,i)=>[...new Set(sudokuUnits.filter(u=>u.includes(i)).flat())].filter(j=>j!==i));
function sudokuCandidates(board,i){
 let mask=1022;
 for(const j of sudokuPeers[i])mask&=~(1<<board[j]);
 return mask;
}
function sudokuValid(board){return board.length===81&&sudokuUnits.every(u=>u.reduce((m,i)=>m|(1<<board[i]),0)===1022);}
function sudokuSolutions(input,limit=2){
 const board=input.slice();let count=0,nodes=0;
 function search(){
  if(++nodes>30000)throw new Error('sudoku_search_limit');
  let pos=-1,bits=0,size=10;
  for(let i=0;i<81;i++)if(!board[i]){const m=sudokuCandidates(board,i),n=m.toString(2).replace(/0/g,'').length;if(!n)return;if(n<size){pos=i;bits=m;size=n;if(n===1)break;}}
  if(pos<0){count++;return;}
  for(let n=1;n<=9&&count<limit;n++)if(bits&(1<<n)){board[pos]=n;search();}board[pos]=0;
 }
 search();return count;
}
// Grade by the deductions required, not just by the number of clues.
function sudokuGrade(input){
 const b=input.slice();let grade=1;
 for(let pass=0;pass<81;pass++){
  if(b.every(Boolean))return grade;
  let progress=false;const candidates=b.map((v,i)=>v?0:sudokuCandidates(b,i));
  for(let i=0;i<81;i++){const m=candidates[i];if(m&&(m&(m-1))===0){b[i]=Math.log2(m);progress=true;break;}}
  if(progress)continue;
  for(const unit of sudokuUnits){for(let n=1;n<=9;n++){const cells=unit.filter(i=>candidates[i]&(1<<n));if(cells.length===1){b[cells[0]]=n;progress=true;grade=2;break;}}if(progress)break;}
  if(!progress)return 3;
 }
 return 3;
}
// Called ONLY by the server with its private per-period/per-level seed.
// The returned payload contains the puzzle, never the solution or seed.
function sudokuPuzzle(seed,level){
 let x=seed>>>0||1;const random=n=>{x^=x<<13;x^=x>>>17;x^=x<<5;return (x>>>0)%n;};
 const shuffle=a=>{for(let i=a.length-1;i>0;i--){const j=random(i+1);[a[i],a[j]]=[a[j],a[i]];}return a;};
 const target=level<=3?1:level<=7?2:3,clues=level===1?46:level<=3?40:level<=7?32:27;
 let best=null,bestGrade=0;
 for(let attempt=0;attempt<12;attempt++){
  const rows=shuffle([0,1,2]).flatMap(b=>shuffle([0,1,2]).map(r=>b*3+r)),cols=shuffle([0,1,2]).flatMap(b=>shuffle([0,1,2]).map(c=>b*3+c)),digits=shuffle([1,2,3,4,5,6,7,8,9]);
  const board=rows.flatMap(r=>cols.map(c=>digits[(r*3+Math.floor(r/3)+c)%9]));
  let count=81;
  for(const i of shuffle(Array.from({length:81},(_,i)=>i))){
   if(count<=clues)break;const old=board[i];board[i]=0;
   let unique=false;try{unique=sudokuSolutions(board)===1;}catch{}
   if(!unique||sudokuGrade(board)>target){board[i]=old;}else count--;
  }
  const grade=sudokuGrade(board);
  if(!best||grade>bestGrade){best=board;bestGrade=grade;}
  if(grade===target)return board;
 }
 if(bestGrade===target)return best;
 // Bounded generation fallback: verified unique puzzles of each deduction tier.
 const base=(target===2?'007104080100038720000600901000803070001059038030210090000080000060701800950020000':'026003051501000083003900000300010000004500702059730000260007000000100005000000040').split('').map(Number);
 const rows=shuffle([0,1,2]).flatMap(b=>shuffle([0,1,2]).map(r=>b*3+r)),cols=shuffle([0,1,2]).flatMap(b=>shuffle([0,1,2]).map(c=>b*3+c)),digits=[0,...shuffle([1,2,3,4,5,6,7,8,9])];
 return rows.flatMap(r=>cols.map(c=>digits[base[r*9+c]]));
}
function sudokuLoad(s,puzzle){
 s.givens=puzzle.slice();s.board=puzzle.slice();s.notes=Array(81).fill(0);s.history=[];s.awaiting=false;s.level=s.score+1;return s;
}
function sudokuStep(s,keys){
 if(s.awaiting)return;
 for(const key of keys){
  if(key==='undo'){
   const prev=s.history.pop();if(prev){s.board[prev[0]]=prev[1];s.notes[prev[0]]=prev[2];}continue;
  }
  const m=/^([vn]):([0-9]{1,2}):([0-9])$/.exec(key);if(!m)continue;
  const i=Number(m[2]),v=Number(m[3]);if(i>80||s.givens[i])continue;
  const previous=[i,s.board[i],s.notes[i]];
  if(m[1]==='n'){if(v&& !s.board[i])s.notes[i]^=1<<v;}
  else{s.board[i]=v;s.notes[i]=0;}
  if(previous[1]!==s.board[i]||previous[2]!==s.notes[i]){s.history.push(previous);if(s.history.length>200)s.history.shift();}
  if(sudokuValid(s.board)){s.score++;s.awaiting=true;s.history=[];break;}
 }
}

function create(game,q,version=ARCADE_VERSION) {
 if(![1,2,3,4].includes(version)){throw new Error("rules_version");}
 if(!GAME_IDS.includes(game)){throw new Error("game");}
 const s={game,version,tick:0,score:0,over:false,q:q.slice(),limit:version===1?LIMITS[game]:null};
 if(game==="sudoku"){sudokuLoad(s,'530070000600195000098000060800060003400803001700020006060000280000419005000080079'.split('').map(Number));s.awaiting=true;}
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
// Version 4: retain sub-unit precision during contact resolution. The persistent
// precise tuple is integer fixed-point; rendered coordinates remain integers.
function mergePhysicsV4(s) {
 const clamp=(v,n)=>Math.max(-n,Math.min(n,v));
 const bodies=s.balls.map(b=>{
  const p=b.precise;
  return {...b,x:p?p[0]/1000:b.x,y:p?p[1]/1000:b.y,vx:p?p[2]/1000:b.vx,vy:p?p[3]/1000:b.vy,
   w:p?p[4]/1e7:(b.spin||0)/10000,a:p?p[5]/1e7:(b.angle||0)/10000,
   startX:p?p[0]/1000:b.x,startY:p?p[1]/1000:b.y,startA:p?p[5]/1e7:(b.angle||0)/10000,contact:false,hit:0};
 });
 let balls=bodies;const merged=new Set();
 for(let sub=0;sub<2;sub++){
  for(const b of balls){b.vy=Math.min(140,b.vy+2);b.x+=b.vx/2;b.y+=b.vy/2;b.a+=b.w/2;b.w*=.998;}
  for(let pass=0;pass<6;pass++){
   const buckets=new Map(),pairs=new Set(),count=balls.length;
   for(let i=0;i<count;i++){
    const b=balls[i],r=RADIUS[b.level];
    for(let x=Math.floor((b.x-r)/500);x<=Math.floor((b.x+r)/500);x++)for(let y=Math.floor((b.y-r)/500);y<=Math.floor((b.y+r)/500);y++){
     const key=x+','+y,ids=buckets.get(key)||[];for(const j of ids)pairs.add(j*count+i);ids.push(i);buckets.set(key,ids);
    }
   }
   const removed=new Set();
   for(const code of [...pairs].sort((a,b)=>a-b)){
    const i=Math.floor(code/count),j=code%count;if(removed.has(i)||removed.has(j))continue;
    const a=balls[i],b=balls[j],ra=RADIUS[a.level],rb=RADIUS[b.level],dx=b.x-a.x,dy=b.y-a.y,rr=ra+rb;
    if(dx*dx+dy*dy>(rr+.5)**2)continue;
    if(a.level===b.level&&a.level<10&&!merged.has(a.id)&&!merged.has(b.id)){
     a.level++;a.x=(a.x+b.x)/2;a.y=(a.y+b.y)/2;a.vx=(a.vx+b.vx)/2;a.vy=(a.vy+b.vy)/2;
     a.w=(a.w+b.w)/2;a.rest=0;a.hit=20;s.score+=2**a.level*10;removed.add(j);merged.add(a.id);continue;
    }
    a.contact=b.contact=true;
    const dist=Math.max(.001,Math.hypot(dx,dy)),nx=dx===0&&dy===0?1:dx/dist,ny=dy/dist,tx=-ny,ty=nx;
    const wa=rb*rb/(ra*ra+rb*rb),wb=1-wa,overlap=Math.max(0,rr-dist-.1)*.8;
    a.x-=nx*overlap*wa;a.y-=ny*overlap*wa;b.x+=nx*overlap*wb;b.y+=ny*overlap*wb;
    const normal=(b.vx-a.vx)*nx+(b.vy-a.vy)*ny,impulse=normal<0?-normal*(normal < -16?1.1:1):0;
    a.hit=Math.max(a.hit,impulse*wa);b.hit=Math.max(b.hit,impulse*wb);
    a.vx-=impulse*nx*wa;a.vy-=impulse*ny*wa;b.vx+=impulse*nx*wb;b.vy+=impulse*ny*wb;
    const slip=(b.vx-a.vx)*tx+(b.vy-a.vy)*ty-a.w*ra-b.w*rb;
    const tangent=clamp(-slip/3,.65*impulse);
    a.vx-=tangent*tx*wa;a.vy-=tangent*ty*wa;b.vx+=tangent*tx*wb;b.vy+=tangent*ty*wb;
    a.w-=2*tangent*wa/ra;b.w-=2*tangent*wb/rb;
   }
   balls=balls.filter((_,i)=>!removed.has(i));
   for(const b of balls){
    const r=RADIUS[b.level];
    if(b.x<=r||b.x>=4000-r){
     const side=b.x<=r?-1:1;b.contact=true;b.x=Math.max(r,Math.min(4000-r,b.x));
     const impact=Math.max(0,b.vx*side);b.hit=Math.max(b.hit,impact);
     if(impact>0)b.vx=-side*impact*(impact>16?.1:0);
     const slip=b.vy+side*b.w*r,f=clamp(slip/3,.45*impact);
     b.vy-=f;b.w-=side*2*f/r;
    }
    if(b.y>=5500-r){
     b.contact=true;b.y=5500-r;const impact=Math.max(0,b.vy);b.hit=Math.max(b.hit,impact);
     if(impact>0)b.vy=impact>16?-impact*.1:0;
     const slip=b.vx-b.w*r,f=clamp(slip/3,.45*impact);
     b.vx-=f;b.w+=2*f/r;
     if(pass===5){b.vx*=.99;b.w*=.99;}
    }
    b.vx=clamp(b.vx,180);b.vy=clamp(b.vy,180);b.w=clamp(b.w,.3);
   }
  }
 }
 s.balls=balls.map(b=>{
  const quiet=b.contact&&b.hit<7&&Math.hypot(b.vx,b.vy)<1.5&&Math.abs(b.w)<.006&&Math.hypot(b.x-b.startX,b.y-b.startY)<1.5;
  const rest=quiet?Math.min(45,(b.rest||0)+1):0;
  // Continue resolving gravity and contacts, so removing support or a new impact
  // wakes the fruit. Only residual velocities of a settled body are zeroed.
  if(rest===45){b.vx=b.vy=b.w=0;b.a=b.startA;}
  const a=(b.a%(Math.PI*2)+Math.PI*2)%(Math.PI*2);
  return {id:b.id,level:b.level,x:Math.round(b.x),y:Math.round(b.y),vx:Math.round(b.vx),vy:Math.round(b.vy),spin:Math.round(b.w*10000),angle:Math.round(a*10000),rest,
   precise:[Math.round(b.x*1000),Math.round(b.y*1000),Math.round(b.vx*1000),Math.round(b.vy*1000),Math.round(b.w*1e7),Math.round(a*1e7)]};
 });
 s.danger=s.balls.some(b=>b.y-RADIUS[b.level]<400)?s.danger+1:0;if(s.danger>180)s.over=true;
}
const BLOCK_KICKS=[[[0,0],[-1,0],[-1,-1],[0,2],[-1,2]],[[0,0],[1,0],[1,1],[0,-2],[1,-2]],[[0,0],[1,0],[1,-1],[0,2],[1,2]],[[0,0],[-1,0],[-1,1],[0,-2],[-1,-2]]];
const LINE_KICKS=[[[0,0],[-2,0],[1,0],[-2,1],[1,-2]],[[0,0],[-1,0],[2,0],[-1,-2],[2,1]],[[0,0],[2,0],[-1,0],[2,-1],[-1,2]],[[0,0],[1,0],[-2,0],[1,2],[-2,-1]]];
function stepBlocksV4(s,keys){
 let adjusted=false;
 if(keys.includes('l')||keys.includes('r')){const next={...s.piece,x:s.piece.x+(keys.includes('l')?-1:1)};if(fits(s,next)){s.piece=next;adjusted=true;}}
 if(keys.includes('u')){
  const current=s.piece,orientation=current.rotation||0,pivot=current.shape===0?1.5:current.shape===1?.5:1;
  const cells=current.shape===undefined?current.cells.map(([x,y])=>[-y,x]):current.cells.map(([x,y])=>[pivot-(y-pivot),pivot+(x-pivot)]);
  if(current.shape===undefined){const minX=Math.min(...cells.map(c=>c[0])),minY=Math.min(...cells.map(c=>c[1]));for(const c of cells){c[0]-=minX;c[1]-=minY;}}
  const kicks=current.shape===0?LINE_KICKS[orientation]:BLOCK_KICKS[orientation];
  for(const [dx,dy] of kicks){const next={...current,cells,x:current.x+dx,y:current.y+dy,rotation:(orientation+1)%4};if(fits(s,next)){s.piece=next;adjusted=true;break;}}
 }
 if(keys.includes('drop')){for(let i=0;i<21;i++)if(!lower(s))break;return;}
 s.fall=(s.fall||0)+1;
 if(keys.includes('d')||s.fall>=Math.max(5,35-Math.floor(s.lines/5))){
  s.fall=0;const next={...s.piece,y:s.piece.y+1};if(fits(s,next)){s.piece=next;s.lock=0;}
 }
 if(fits(s,{...s.piece,y:s.piece.y+1})){s.lock=0;}else{
  if(adjusted&&(s.lockResets||0)<15){s.lock=0;s.lockResets=(s.lockResets||0)+1;}
  s.lock=(s.lock||0)+1;if(s.lock>=30)lower(s);
 }
}
function clearHexV4(s){
 let chain=0;
 for(let pass=0;pass<20;pass++){
  const seen=new Set(),remove=new Set();
  for(let side=0;side<6;side++)for(let i=0;i<s.lanes[side].length;i++){
   const id=side*16+i;if(seen.has(id))continue;
   const group=[],todo=[[side,i]],color=s.lanes[side][i];seen.add(id);
   while(todo.length){const [a,b]=todo.pop();group.push(a*16+b);
    for(const [c,d] of [[(a+5)%6,b],[(a+1)%6,b],[a,b-1],[a,b+1]]){
     const key=c*16+d;if(d>=0&&s.lanes[c][d]===color&&!seen.has(key)){seen.add(key);todo.push([c,d]);}
    }
   }
   if(group.length>=3)for(const key of group)remove.add(key);
  }
  if(!remove.size)break;chain++;s.score+=Math.floor(remove.size*100/3)*chain;
  s.lanes=s.lanes.map((lane,side)=>lane.filter((_,i)=>!remove.has(side*16+i)));
 }
}
// Swept circle-versus-expanded rectangle: choose the first contact along the
// path, then spend the remainder of the fixed tick after reflection.
function sweptBox(x,y,dx,dy,left,top,right,bottom){
 let enter=-Infinity,exit=Infinity,nx=0,ny=0;
 for(const [p,v,lo,hi,ax,ay] of [[x,dx,left,right,1,0],[y,dy,top,bottom,0,1]]){
  if(Math.abs(v)<1e-9){if(p<lo||p>hi)return null;continue;}
  let a=(lo-p)/v,b=(hi-p)/v,sign=-1;if(a>b){[a,b]=[b,a];sign=1;}
  if(a>enter+1e-8){enter=a;nx=ax*sign;ny=ay*sign;}else if(Math.abs(a-enter)<1e-8){nx+=ax*sign;ny+=ay*sign;}
  exit=Math.min(exit,b);if(enter>exit)return null;
 }
 return enter>=-1e-8&&enter<=1&&exit>=0?{t:Math.max(0,enter),nx,ny}:null;
}
function stepBricksV4(s,keys){
 const left=keys.includes('l'),right=keys.includes('r'),aim=keys.find(k=>k.startsWith('x:'));
 if(aim)s.target=Math.max(450,Math.min(3550,Number(aim.slice(2))));
 if(left||right)delete s.target;
 if(s.target!==undefined)s.paddle+=Math.max(-65,Math.min(65,s.target-s.paddle));
 if(left)s.paddle-=65;if(right)s.paddle+=65;s.paddle=Math.max(450,Math.min(3550,s.paddle));
 let time=1;
 for(let bounce=0;bounce<6&&time>1e-6;bounce++){
  const dx=s.vx*time,dy=s.vy*time;let hit=null;
  const offer=(h,type,index)=>{if(h&&h.t>=0&&h.t<=1&&(!hit||h.t<hit.t-1e-8))hit={...h,type,index};};
  if(dx<0)offer({t:(60-s.x)/dx,nx:1,ny:0},'wall');
  if(dx>0)offer({t:(3940-s.x)/dx,nx:-1,ny:0},'wall');
  if(dy<0)offer({t:(60-s.y)/dy,nx:0,ny:1},'wall');
  if(hit&&(hit.t<0||hit.t>1))hit=null;
  if(dy>0&&s.y<=5020){const t=(5020-s.y)/dy;if(t>=0&&t<=1&&Math.abs(s.x+dx*t-s.paddle)<=500)offer({t,nx:0,ny:-1},'paddle');}
  for(let i=0;i<48;i++)if(s.board[i]){const x=100+i%8*475,y=600+Math.floor(i/8)*220;offer(sweptBox(s.x,s.y,dx,dy,x-60,y-60,x+495,y+240),'brick',i);}
  if(!hit){s.x+=dx;s.y+=dy;break;}
  s.x+=dx*hit.t;s.y+=dy*hit.t;time*=1-hit.t;
  if(hit.type==='brick'){s.board[hit.index]--;if(!s.board[hit.index])s.score+=100;}
  if(hit.type==='paddle'){
   const speed=Math.min(72,45+((s.wave||1)-1)*3),offset=Math.max(-1,Math.min(1,(s.x-s.paddle)/500));
   let angle=offset*Math.PI/3;if(Math.abs(angle)<.12)angle=(s.vx<0?-1:1)*.12;
   s.vx=speed*Math.sin(angle);s.vy=-speed*Math.cos(angle);
  }else{if(hit.nx)s.vx=-s.vx;if(hit.ny)s.vy=-s.vy;}
  s.x+=hit.nx*.01;s.y+=hit.ny*.01;
 }
 for(const key of ['x','y','vx','vy'])s[key]=Math.round(s[key]);
 if(s.y>5600){s.lives--;if(!s.lives)s.over=true;else{s.x=s.paddle;s.y=4700;s.vx=27;s.vy=-36;}}
 if(!s.board.some(Boolean))nextWave(s);
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
 if(s.game==='sudoku'){s.tick++;sudokuStep(s,keys);return s;}
 if(s.q.length<4){throw new Error("queue_empty");}
 s.tick++;
 const has=(k)=>keys.includes(k), left=has('l'),right=has('r');
 if(s.game==='2048'){const dir=keys.find(k=>['l','r','u','d'].includes(k));if(dir){slide(s,dir);}}
 if(s.game==='blocks'&&s.version>=4){stepBlocksV4(s,keys);}
 if(s.game==='blocks'&&s.version<4){
  if(left||right){const p={...s.piece,x:s.piece.x+(left?-1:1)};if(fits(s,p)){s.piece=p;}}
  if(has('u')){const p={...s.piece,cells:s.piece.cells.map(([x,y])=>[-y,x])};const minX=Math.min(...p.cells.map(c=>c[0])),minY=Math.min(...p.cells.map(c=>c[1]));p.cells=p.cells.map(([x,y])=>[x-minX,y-minY]);if(fits(s,p)){s.piece=p;}}
  if(has('drop')){for(let i=0;i<21;i++){if(!lower(s)){break;}}}else if(has('d')||s.tick%Math.max(s.version===1?8:5,35-Math.floor(s.lines/5))===0){lower(s);}
 }
 if(s.game==='snake'){
  const dir=keys.map(k=>['u','r','d','l'].indexOf(k)).find(d=>d>=0);if(dir!==undefined&&(dir+2)%4!==s.dir&&!s.turned&&(s.version<4||dir!==s.dir)){s.dir=dir;s.turned=true;}
  if(s.tick%7===0){s.turned=false;const h=s.snake[0],x=h%20,y=Math.floor(h/20),nx=x+[0,1,0,-1][s.dir],ny=y+[-1,0,1,0][s.dir],n=ny*20+nx,eat=n===s.food;
   if(nx<0||nx>=20||ny<0||ny>=20||s.walls.includes(n)||s.snake.slice(0,eat?undefined:-1).includes(n)){s.over=true;}else{s.snake.unshift(n);if(eat){s.score+=100;food(s);}else{s.snake.pop();}}
  }
 }
 if(s.game==='bird'){
  if(has('tap')||has('u')){s.vy=-65;}s.vy+=3;s.y+=s.vy;
  if(s.tick>=s.next){s.pipes.push({x:4200,gap:1300+take(s,2700),passed:false,...(s.version>=2?{half:Math.max(600,750-Math.floor(s.score/15)*15)}:{})});s.next=s.tick+120;}
  for(const p of s.pipes){p.x-=s.version===1?25:Math.min(40,25+Math.floor(s.score/20));if(!p.passed&&p.x+400<900){p.passed=true;s.score++;}if(s.version>=3?birdHitsPipe(s.y,p):(p.x<1050&&p.x+400>750&&(s.y-120<p.gap-(p.half||750)||s.y+120>p.gap+(p.half||750)))){s.over=true;}}
  s.pipes=s.pipes.filter(p=>p.x>-500);if(s.version>=4&&s.y<85){s.y=85;s.vy=Math.max(0,s.vy);}if(s.y<(s.version>=3?85:120)||s.y>(s.version>=3?5515:5480)){s.over=true;}
 }
 if(s.game==='hex'){
  if(left){s.rotation=(s.rotation+5)%6;}if(right){s.rotation=(s.rotation+1)%6;}
  if(!s.falling){s.falling={lane:take(s,6),color:take(s,4)+1,distance:1900};}
  s.falling.distance-=12+Math.min(s.version===1?20:28,Math.floor(s.score/300));
  const lane=(s.falling.lane-s.rotation+6)%6,stack=s.lanes[lane];
  if(s.falling.distance<=stack.length*160){stack.push(s.falling.color);s.falling=null;const n=stack.length;if(s.version>=4){clearHexV4(s);}else if(n>=3&&stack[n-1]===stack[n-2]&&stack[n-2]===stack[n-3]){stack.splice(n-3,3);s.score+=100;}if((s.version>=4?s.lanes[lane]:stack).length>=10){s.over=true;}}
 }
 if(s.game==='bricks'&&s.version>=4){stepBricksV4(s,keys);}
 if(s.game==='bricks'&&s.version<4){
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
  if(s.version===1){mergePhysics(s);}else{if(s.version>=4){mergePhysicsV4(s);}else if(s.version>=3){mergePhysicsV3(s);}else{mergePhysicsV2(s);}s.aim=Math.max(RADIUS[s.next],Math.min(4000-RADIUS[s.next],s.aim));}if(s.version===1&&s.drops>=100&&!s.cooldown){s.over=true;}
 }
 if(s.limit!==null&&s.tick>=s.limit){s.over=true;}return s;
}
function advance(state,frames,events){
 if(!Number.isInteger(frames)||frames<0||frames>180||!Array.isArray(events)||events.length>360){throw new Error('invalid_actions');}
 const s=clone(state), grouped={};let previous=-1;
 for(const e of events){if(!Array.isArray(e)||e.length!==2||!Number.isInteger(e[0])||e[0]<0||e[0]>=frames||e[0]<previous||typeof e[1]!=='string'||!(/^(l|r|u|d|drop|tap|x:[0-9]{1,4}|[vn]:[0-9]{1,2}:[0-9]|undo)$/).test(e[1])){throw new Error('invalid_actions');}previous=e[0];(grouped[e[0]]||= []).push(e[1]);if(grouped[e[0]].length>2){throw new Error('invalid_actions');}}
 if(s.game==='2048'&&(frames>16||Object.values(grouped).some(keys=>keys.length>1||!['l','r','u','d'].includes(keys[0])))){throw new Error('invalid_actions');}
 for(let i=0;i<frames;i++){if(s.over){throw new Error('already_over');}step(s,grouped[i]||[]);}return s;
}
function preview(state,dir){const s=clone(state);slide(s,dir,false);s.tick++;return s;}
const ArcadeCore={sudokuPuzzle,sudokuLoad,sudokuValid,sudokuSolutions,sudokuGrade,preview,version:ARCADE_VERSION,games:GAME_IDS,limits:LIMITS,radii:RADIUS,create,step,advance};


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

  get sudoku() { return this.run.game === "sudoku"; }
  get grid() { return this.run.game === "2048"; }
  get privateGrid() { return this.grid && !Array.isArray(this.state.q); }
  get blocked() {
    if(this.sudoku){return this.state.awaiting || this.frames>=120;}
    return this.privateGrid ? !!this.pending || this.frames > 0 : this.frames >= (this.grid ? 16 : 180) || this.state.q.length < 4;
  }
  get needsSync() {
    if(this.sudoku){return this.frames>0 && (this.state.awaiting || this.frames>=20);}
    return this.frames > 0 && (this.privateGrid || this.frames >= (this.grid ? 4 : 120) || this.state.over || this.state.q.length < 8);
  }

  input(key) {
    if(this.sudoku && (this.state.awaiting || !/^(?:[vn]:[0-9]{1,2}:[0-9]|undo)$/.test(key))){return;}
    if (this.state.over || this.run.status !== "playing") { return; }
    if ((this.grid || this.run.game === "snake") && !["l", "r", "u", "d"].includes(key)) { return; }
    if (this.run.game === "snake") {
      const dirs=["u","r","d","l"], next=dirs.indexOf(key);
      const last=this.keys.length?dirs.indexOf(this.keys[this.keys.length-1]):this.state.dir;
      if(next===last||(next+2)%4===last||this.keys.length>=2){return;}
    }
    // Multiple events within one simulation frame are one flap, not a backlog.
    if(this.run.game === "bird" && this.keys.includes(key)){return;}
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
    if (this.grid || this.sudoku) {
      const key = this.keys.shift();
      if (!key) { return false; }
      if(!this.sudoku)this.visualMove = {direction:key,board:this.state.board.slice(),tick:this.state.tick+1};
      if(this.privateGrid){this.state=Core.preview(this.state,key);}else{Core.step(this.state,[key]);}
      this.events.push([this.frames,key]);
      this.frames++;
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
    const previousLevel=this.state.level;
    const state = Core.advance(run.state, run.status === "playing" ? this.frames : 0, run.status === "playing" ? this.events : []);
    this.run = run;
    this.state = state;
    this.pending = null;
    if(this.sudoku && run.state.level!==previousLevel){this.keys=[];}
    if (run.status !== "playing") { this.frames=0;this.events=[];this.keys = []; this.release(); }
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
      const occupied=new Set(this.motion.tracks.map(t=>t.to));
      s.board.forEach((v,i)=>{if(v&&!occupied.has(i)){this.pops.set(i,now+110);}});
    }
    if(before){
      if(s.score>before.score){this.scoreGain={amount:s.score-before.score,start:now};}
      if(s.game==='2048'&&s.tick===before.tick){
        s.board.forEach((v,i)=>{if(v&&!before.board[i]){this.pops.set(i,now);}});
      }
      if(s.game==='blocks'&&s.lines>before.lines){
        const full=before.board.slice();before.piece?.cells.forEach(([x,y])=>{const i=(y+before.piece.y)*10+x+before.piece.x;if(i>=0&&i<200){full[i]=1;}});
        for(let row=0;row<20;row++){if(full.slice(row*10,row*10+10).every(Boolean)){for(let x=0;x<5;x++)this.burst(36+x*56,row*28+22,'#c3f0d7',now,22);}}
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
        const old=new Map(before.balls.map(b=>[b.id,b.level]));
        s.balls.forEach(b=>{if(!old.has(b.id)||b.level>old.get(b.id)){this.burst(b.x/10,b.y/10,'#f6df9c',now,18+b.level*3);this.pops.set(b.id,now);}});
      }
    }
    this.previous={game:s.game,tick:s.tick,score:s.score,lines:s.lines,food:s.food,rotation:s.rotation,lives:s.lives,
      board:s.board?.slice(),piece:s.piece?{...s.piece}:null,snake:s.snake?.slice(),lanes:s.lanes?.map(l=>l.slice()),balls:s.balls?.map(b=>({id:b.id,level:b.level}))};
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
  overlay(ctx,now,scoreColor='#e5f6c6',centerX=200){
    if(this.reducedMotion)return;
    for(const b of this.bursts){const t=(now-b.start)/500;if(t<0||t>1)continue;ctx.save();ctx.globalAlpha=1-t;ctx.strokeStyle=b.color;ctx.lineWidth=2;ctx.beginPath();ctx.arc(b.x,b.y,b.radius*(.5+t),0,Math.PI*2);ctx.stroke();
      ctx.fillStyle=b.color;for(let i=0;i<8;i++){const a=i*Math.PI/4,d=b.radius*t*2.3;ctx.fillRect(b.x+Math.cos(a)*d-1.5,b.y+Math.sin(a)*d-1.5,3,3);}ctx.restore();}
    const gain=this.scoreGain;if(gain){const t=(now-gain.start)/650;if(t>=0&&t<1){ctx.save();ctx.globalAlpha=1-t;ctx.fillStyle=scoreColor;ctx.font='700 22px system-ui';ctx.textAlign='center';ctx.fillText(`+${gain.amount}`,centerX,36-t*18);ctx.restore();}}
  }
}

return ArcadeEffects;
})();
const draw=(()=>{
const BLOCK_COLORS=['#6dc9e8','#e9d578','#ba9dea','#84ddc0','#f389a2','#7f9ae0','#f6bf70'];
const PALETTE=['#84ddc0','#f6bf70','#9b9ef1','#f389a2','#6dc9e8','#e9d578','#ba9dea'];
function draw(canvas,s,fx=null,now=performance.now()) {
 const ctx=canvas.getContext('2d');if(!ctx){return;}const width=s.game==='blocks'?296:400,height=s.game==='blocks'?576:s.game==='sudoku'||s.game==='2048'||s.game==='snake'||s.game==='hex'?400:560;
 const scale=Math.min(window.devicePixelRatio||1,2);if(canvas.width!==width*scale||canvas.height!==height*scale){canvas.width=width*scale;canvas.height=height*scale;canvas.style.aspectRatio=`${width}/${height}`;}
 ctx.setTransform(scale,0,0,scale,0,0);ctx.fillStyle='#102c39';ctx.fillRect(0,0,width,height);
 const box=(x,y,w,h,color,r=6)=>{ctx.fillStyle=color;ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fill();};
 const text=(v,x,y,size=24,color='#effaf8')=>{ctx.fillStyle=color;ctx.font=`700 ${size}px system-ui`;ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillText(String(v),x,y);};
 if(s.game==='sudoku'){
  ctx.fillStyle='#f7f6fb';ctx.fillRect(0,0,400,400);
  for(let i=0;i<81;i++){const x=20+i%9*40,y=20+Math.floor(i/9)*40;if(s.board[i])text(s.board[i],x+20,y+20,23,'#454168');}
  for(let i=0;i<=9;i++){ctx.strokeStyle=i%3===0?'#756d98':'#dcd8e8';ctx.lineWidth=i%3===0?2:1;ctx.beginPath();ctx.moveTo(20+i*40,20);ctx.lineTo(20+i*40,380);ctx.moveTo(20,20+i*40);ctx.lineTo(380,20+i*40);ctx.stroke();}
 }
 if(s.game==='2048'){
  ctx.fillStyle='#bbada0';ctx.fillRect(0,0,400,400);
  const tileColors=['#eee4da','#ede0c8','#f2b179','#f59563','#f67c5f','#f65e3b','#edcf72','#edcc61','#edc850','#edc53f','#edc22e'];
  const tile=(v,i,scale=1,x=null,y=null)=>{x=x??12+i%4*97;y=y??12+Math.floor(i/4)*97;ctx.save();ctx.translate(x+42.5,y+42.5);ctx.scale(scale,scale);box(-42.5,-42.5,85,85,tileColors[Math.min(Math.log2(v)-1,tileColors.length-1)],9);text(v,0,0,v>=10000?21:v>=1000?26:31,v<8?'#776e65':'#f9f6f2');ctx.restore();};
  for(let i=0;i<16;i++)box(12+i%4*97,12+Math.floor(i/4)*97,85,85,'#cdc1b4',9);
  const m=fx?.motion,t=m?Math.min(1,Math.max(0,(now-m.start)/110)):1;
  if(m&&t<1&&!fx.reducedMotion){const ease=1-(1-t)**3;m.tracks.forEach(track=>{const x=12+(track.from%4+(track.to%4-track.from%4)*ease)*97,y=12+(Math.floor(track.from/4)+(Math.floor(track.to/4)-Math.floor(track.from/4))*ease)*97;tile(track.value,track.to,1,x,y);});}
  else{s.board.forEach((v,i)=>{if(v)tile(v,i,fx?.pop?.(i,now)||1);});}
 }
 if(s.game==='blocks'){
  // Exactly ten columns; the frame is outside the playable rectangle.
  ctx.fillStyle='#557782';ctx.fillRect(0,0,width,height);
  ctx.save();ctx.translate(-52,8);ctx.fillStyle='#102c39';ctx.fillRect(60,0,280,560);
  const cell=(i,v)=>{if(v){box(61+i%10*28,Math.floor(i/10)*28+1,26,26,BLOCK_COLORS[(v-1)%7],4);box(64+i%10*28,Math.floor(i/10)*28+3,20,3,'#ffffff35',1);}};
  ctx.strokeStyle='#23424f';for(let x=60;x<=340;x+=28){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,560);ctx.stroke();}
  for(let y=0;y<=560;y+=28){ctx.beginPath();ctx.moveTo(60,y);ctx.lineTo(340,y);ctx.stroke();}
  s.board.forEach((v,i)=>cell(i,v));if(s.piece){
   let ghost=s.piece.y;
   const fits=y=>s.piece.cells.every(([x,dy])=>{x+=s.piece.x;dy+=y;return x>=0&&x<10&&dy>=0&&dy<20&&!s.board[dy*10+x];});
   while(fits(ghost+1))ghost++;
   ctx.save();ctx.strokeStyle=BLOCK_COLORS[(s.piece.color-1)%7];ctx.globalAlpha=.55;ctx.lineWidth=1.5;s.piece.cells.forEach(([x,y])=>{ctx.beginPath();ctx.roundRect(62+(x+s.piece.x)*28,(y+ghost)*28+2,24,24,4);ctx.stroke();});ctx.restore();
   s.piece.cells.forEach(([x,y])=>cell((y+s.piece.y)*10+x+s.piece.x,s.piece.color));
  }
  ctx.restore();
 }
 if(s.game==='snake'){
  ctx.fillStyle='#e3edca';ctx.fillRect(0,0,400,400);
  ctx.fillStyle='#dce7c1';for(let y=0;y<20;y++)for(let x=0;x<20;x++)if((x+y)%2)ctx.fillRect(x*20,y*20,20,20);
  ctx.strokeStyle='#6d8c57';ctx.lineWidth=3;ctx.strokeRect(0,0,400,400);ctx.lineWidth=1;
  s.walls.forEach(i=>box(i%20*20+1,Math.floor(i/20)*20+1,18,18,'#77836d',3));
  const movement=fx?.snakeMove,t=movement&&!fx.reducedMotion?Math.min(1,Math.max(0,(now-movement.start)/85)):1;
  s.snake.forEach((i,k)=>{const old=movement?.from[Math.min(k,movement.from.length-1)]??i;const x=(old%20+(i%20-old%20)*t)*20,y=(Math.floor(old/20)+(Math.floor(i/20)-Math.floor(old/20))*t)*20;box(x+1,y+1,18,18,k?'#4d986d':'#2e7655',5);if(!k){const dx=[0,1,0,-1][s.dir],dy=[-1,0,1,0][s.dir];ctx.fillStyle='#ffffff';for(const side of [-1,1]){ctx.beginPath();ctx.arc(x+10+dx*5+dy*side*4,y+10+dy*5-dx*side*4,2.3,0,7);ctx.fill();}}});
  const foodX=s.food%20*20,foodY=Math.floor(s.food/20)*20;box(foodX+3,foodY+5,14,13,'#d75e62',6);box(foodX+9,foodY+1,6,4,'#538853',2);
 }
 if(s.game==='bird'){
  const sky=ctx.createLinearGradient(0,0,0,560);sky.addColorStop(0,'#9dd6e4');sky.addColorStop(1,'#e6f2e2');ctx.fillStyle=sky;ctx.fillRect(0,0,400,560);
  ctx.fillStyle='#ffffffa0';for(let i=0;i<5;i++){const x=((i*113-s.tick*.12)%560+560)%560-80,y=80+i%3*100;box(x,y,75,18,'#ffffffa0',9);ctx.beginPath();ctx.arc(x+25,y,20,0,7);ctx.arc(x+48,y+2,15,0,7);ctx.fill();}
  box(0,558,400,2,'#7faf8d',0);
  s.pipes.forEach(p=>{const x=p.x/10,top=(p.gap-(p.half||750))/10,bottom=(p.gap+(p.half||750))/10;
   box(x,0,40,top,'#43856c',3);box(x,bottom,40,560-bottom,'#43856c',3);
   box(x+4,0,9,top,'#8acba0',2);box(x+4,bottom,9,560-bottom,'#8acba0',2);
   box(x,top-12,40,12,'#69aa7e',2);box(x,bottom,40,12,'#69aa7e',2);
  });
  ctx.save();ctx.translate(90,s.y/10);ctx.rotate(Math.max(-.4,Math.min(.7,s.vy/120)));box(-15,-12,30,24,'#f8ce63',10);box(2,-9,11,11,'#fffaf0',5);ctx.fillStyle='#173849';ctx.beginPath();ctx.arc(8,-4,3,0,7);ctx.fill();ctx.save();ctx.translate(-7,3);ctx.rotate(fx?.reducedMotion?0:Math.sin(s.tick*.8)*.55);box(-8,-2,16,8,'#f3a872',5);ctx.restore();ctx.fillStyle='#f0a45d';ctx.beginPath();ctx.moveTo(13,-1);ctx.lineTo(23,3);ctx.lineTo(13,6);ctx.fill();ctx.restore();
 }
 if(s.game==='hex'){
  ctx.fillStyle='#f0f2f6';ctx.fillRect(0,0,400,400);
  // Fit the entire six-lane arena, including arrivals, inside the square canvas.
  ctx.translate(200,200);ctx.scale(.68,.68);ctx.translate(-200,-280);
  const cx=200,cy=280,hex=(radius)=>{ctx.beginPath();for(let i=0;i<6;i++){const a=i*Math.PI/3+Math.PI/6;ctx.lineTo(cx+Math.cos(a)*radius,cy+Math.sin(a)*radius);}ctx.closePath();};
  for(const radius of [90,145,205,282]){hex(radius);ctx.strokeStyle=radius===282?'#d4d9e3':'#e1e5ec';ctx.lineWidth=1.5;ctx.stroke();}
  const rotation=fx?.rotation?.(s,now)??s.rotation;ctx.save();ctx.translate(cx,cy);ctx.rotate(rotation*Math.PI/3);ctx.translate(-cx,-cy);hex(50);ctx.fillStyle='#46576f';ctx.fill();hex(41);ctx.strokeStyle='#ffffff30';ctx.stroke();ctx.restore();
  const colors=['#df748e','#e9b44f','#68bda6','#7f8ed1'];
  const block=(lane,dist,color)=>{const a=lane*Math.PI/3;ctx.save();ctx.translate(cx,cy);ctx.rotate(a);const inner=dist-7,outer=dist+7;ctx.beginPath();ctx.moveTo(inner,-inner/Math.sqrt(3)+2);ctx.lineTo(outer,-outer/Math.sqrt(3)+2);ctx.lineTo(outer,outer/Math.sqrt(3)-2);ctx.lineTo(inner,inner/Math.sqrt(3)-2);ctx.closePath();ctx.fillStyle=colors[(color-1)%4];ctx.fill();ctx.strokeStyle='#ffffff70';ctx.lineWidth=1;ctx.stroke();ctx.restore();};
  s.lanes.forEach((lane,i)=>lane.forEach((c,j)=>block((i+rotation)%6,52+j*16,c)));
  if(s.falling){block(s.falling.lane,52+s.falling.distance/10,s.falling.color);}
 }
 if(s.game==='bricks'){
  const court=ctx.createLinearGradient(0,0,0,560);court.addColorStop(0,'#1d2443');court.addColorStop(1,'#142e40');ctx.fillStyle=court;ctx.fillRect(0,0,400,560);
  ctx.fillStyle='#ffffff12';for(let x=20;x<400;x+=24)for(let y=24;y<500;y+=24)ctx.fillRect(x,y,1,1);
  ctx.strokeStyle='#7481a0';ctx.lineWidth=3;ctx.beginPath();ctx.moveTo(0,560);ctx.lineTo(0,0);ctx.lineTo(400,0);ctx.lineTo(400,560);ctx.stroke();ctx.lineWidth=1;
  s.board.forEach((v,i)=>{if(v){box(10+i%8*47.5,60+Math.floor(i/8)*22,43.5,18,PALETTE[(Math.floor(i/8)+(s.wave||1)-1)%7],4);box(13+i%8*47.5,62+Math.floor(i/8)*22,37.5,3,'#ffffff50',1);if(v>1)text(v,31.75+i%8*47.5,69+Math.floor(i/8)*22,12,'#203448');}});
  if(fx&&!fx.reducedMotion){fx.trail.forEach((point,i)=>{ctx.save();ctx.globalAlpha=(i+1)/fx.trail.length*.22;ctx.fillStyle='#fff0ba';ctx.beginPath();ctx.arc(point.x,point.y,2+i*.4,0,7);ctx.fill();ctx.restore();});}
  box(s.paddle/10-45,508,90,10,'#80cdbd',5);box(s.paddle/10-38,509,76,2,'#e3fff3',1);ctx.beginPath();ctx.arc(s.x/10,s.y/10,6,0,7);ctx.fillStyle='#fff0ba';ctx.fill();text('●'.repeat(s.lives),200,540,15,'#91c9be');
 }
 if(s.game==='merge'){
  // The launch rail follows the current fruit radius and the actual walls.
  const backdrop=ctx.createLinearGradient(0,0,0,550);backdrop.addColorStop(0,'#f8f1df');backdrop.addColorStop(1,'#e8d6b6');ctx.fillStyle=backdrop;ctx.fillRect(0,0,400,550);
  ctx.fillStyle='#aa8b61';ctx.fillRect(0,550,400,10);
  ctx.strokeStyle='#aa8b61';ctx.lineWidth=4;ctx.beginPath();ctx.moveTo(0,54);ctx.lineTo(0,550);ctx.lineTo(400,550);ctx.lineTo(400,54);ctx.stroke();ctx.lineWidth=1;
  const edge=s.version===1?50:Core.radii[s.next]/10;box(0,0,400,50,'#e1d0b0',0);box(edge,23,400-2*edge,4,'#aa8b61',2);
  for(const x of [edge,400-edge]){box(x-2,17,4,16,'#8a6d46',2);}
  ctx.strokeStyle=s.danger?'#c33c53':'#a7896380';ctx.setLineDash([5,6]);ctx.beginPath();ctx.moveTo(8,40);ctx.lineTo(392,40);ctx.stroke();ctx.setLineDash([]);
  const fruit=(x,y,level,ghost=false,pop=1,angle=0)=>{const r=Core.radii[level]/10*pop,img=fx?.sprites?.[level];ctx.save();ctx.globalAlpha=ghost?.7:1;ctx.shadowColor='#61452325';ctx.shadowBlur=5;ctx.shadowOffsetY=3;ctx.beginPath();ctx.arc(x,y,r,0,7);ctx.fillStyle='#fff5da';ctx.fill();ctx.shadowBlur=0;ctx.shadowOffsetY=0;ctx.beginPath();ctx.arc(x,y,r,0,7);if(img?.complete&&img.naturalWidth){ctx.clip();ctx.imageSmoothingEnabled=true;ctx.imageSmoothingQuality='high';ctx.translate(x,y);ctx.rotate(angle);ctx.drawImage(img,-r,-r,r*2,r*2);}else{ctx.fillStyle=PALETTE[level%7];ctx.fill();text(level+1,x,y,r);}ctx.restore();ctx.save();ctx.strokeStyle='#ffffff80';ctx.lineWidth=1;ctx.beginPath();ctx.arc(x,y,r-.5,0,7);ctx.stroke();ctx.restore();};
  if(s.version>=2||s.drops<100){const aim=s.aim/10;const first=s.balls.filter(b=>Math.abs(b.x-s.aim)<Core.radii[b.level]).reduce((v,b)=>Math.min(v,(b.y-Core.radii[b.level])/10),550);ctx.save();ctx.strokeStyle='#896b46aa';ctx.setLineDash([3,7]);ctx.beginPath();ctx.moveTo(aim,50);ctx.lineTo(aim,Math.max(50,first));ctx.stroke();ctx.restore();}
  s.balls.forEach(b=>fruit(b.x/10,b.y/10,b.level,false,fx?.pop?.(b.id,now)||1,(b.angle||0)/10000));if(s.version>=2||s.drops<100){fruit(s.aim/10,25,s.next);if(s.cooldown){box(s.aim/10-18,48,36*(1-s.cooldown/(s.version===1?45:24)),2,'#b3ead8',1);}}

 }
 fx?.overlay?.(ctx,now,['2048','snake','merge','hex','bird'].includes(s.game)?'#5e6241':'#e5f6c6',width/2);
}

return draw;
})();
const {loadMergeSprites}=(()=>{
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

return {loadMergeSprites};
})();
const {formatDateTime}=(()=>{
// Kept identical in the six standalone campus plugins; no cross-plugin dependency.
const FALLBACK_TIME_ZONE = "Asia/Shanghai";

function browserTimeZone() {
  try {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;
    if (zone) {
      new Intl.DateTimeFormat(undefined, { timeZone: zone }).format(0);
      return zone;
    }
  } catch {}
  return FALLBACK_TIME_ZONE;
}

function asDate(value) {
  if (value === null || value === undefined || value === "") { return null; }
  let input = value;
  // Historical timestamps without an offset used UTC+8. Date-only values are
  // calendar dates, not instants, and must not move to the previous day.
  if (typeof input === "string") {
    input = input.trim();
    if (/^\d{4}-\d{2}-\d{2}$/.test(input)) { input += "T00:00:00+08:00"; }
    else if (/^\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?$/.test(input)) {
      input = input.replace(" ", "T") + "+08:00";
    }
  }
  const date = new Date(input);
  return Number.isNaN(date.getTime()) ? null : date;
}

function format(value, kind) {
  if (typeof value === "string" && /^\d{4}-\d{2}-\d{2}$/.test(value)) {
    return kind === "time" ? "—" : value;
  }
  const date = asDate(value);
  if (!date) { return "—"; }
  const options = { timeZone: browserTimeZone() };
  if (kind !== "time") { Object.assign(options, { year: "numeric", month: "2-digit", day: "2-digit" }); }
  if (kind !== "date") { Object.assign(options, { hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23" }); }
  try { return new Intl.DateTimeFormat(undefined, options).format(date); }
  catch {
    // Even without a working Intl implementation, never silently use UTC.
    const shifted = new Date(date.getTime() + 8 * 60 * 60 * 1000).toISOString();
    const day = shifted.slice(0, 10), time = shifted.slice(11, 19);
    return kind === "date" ? day : kind === "time" ? time : day + " " + time;
  }
}
const formatDateTime = (value) => format(value, "datetime");
const formatDate = (value) => format(value, "date");
const formatTime = (value) => format(value, "time");

return {formatDateTime};
})();
const drawCover=(()=>{
function drawCover(canvas,game){
  let alive=true;
  const s=Core.create(game,Array(24).fill(3733));
  if(game==='2048')s.board=[2,4,8,0,4,16,64,2,8,32,128,4,16,64,256,8];
  if(game==='blocks'){
   s.board=s.board.map((_,i)=>{const x=i%10,y=Math.floor(i/10),h=[6,5,3,4,2,2,3,5,4,6][x];return y>=20-h?(Math.floor(x/2)+Math.floor(y/2))%7+1:0;});
   s.piece={cells:[[0,0],[1,0],[2,0],[1,1]],x:3,y:11,color:3};
  }
  if(game==='snake'){s.snake=[148,147,146,145,165,185,205,225,226,227,228,229,209,189];s.dir=1;s.food=152;}
  if(game==='bird'){s.y=2670;s.pipes=[{x:1800,gap:2700},{x:3450,gap:3300}];}
  if(game==='hex'){s.lanes=[[1,1,3],[2,2],[3,3,4,4],[4,1],[1,2,2],[2,3,3,4]];s.falling={lane:1,distance:1550,color:2};}
  if(game==='bricks'){s.board=s.board.map((v,i)=>i>24&&i%3===0?0:v);s.x=2750;s.y=3050;s.paddle=2500;}
  if(game==='merge'){s.balls=[{id:1,x:850,y:4750,level:9},{id:2,x:2440,y:4600,level:10},{id:3,x:1430,y:3440,level:7},{id:4,x:3330,y:3400,level:6},{id:5,x:440,y:3520,level:5}];}
  const paint=(sprites=null)=>{if(alive)draw(canvas,s,{sprites,reducedMotion:true},0);};
  paint();if(game==='merge')loadMergeSprites().then(paint);
  return()=>{alive=false;};

}

return drawCover;
})();
const {renderArcade}=(()=>{
const escape=(value)=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const button=(action,label,cls='btn btn-flat',arg='')=>`<button type="button" class="${cls}" data-action="${action}" data-arg="${escape(arg)}">${label}</button>`;
const icon=(kind)=>kind==='info'?'<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 11v6M12 7v1" fill="none" stroke="currentColor" stroke-width="2.5"/></svg>':'<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 10a8 8 0 0 0-14-4L3 9m0-6v6h6M4 14a8 8 0 0 0 14 4l3-3m0 6v-6h-6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
function userHTML(user){
 if(!user?.username){return '<span class="rsc-user-label">—</span>';}
 const name=escape(user.username),href='/u/'+encodeURIComponent(user.username);
 let avatar='';try{const url=new URL(String(user.avatar_template||'').replace('{size}','48'),location.origin);if(['https:','http:'].includes(url.protocol)&&!url.username&&!url.password){avatar=`<img src="${escape(url.href)}" width="24" height="24" alt="" loading="lazy">`;}}catch{}
 return `<a class="rsc-forum-user" href="${escape(href)}" data-user-card="${name}" data-action="profile" data-arg="${name}">${avatar}<span>${name}</span></a>`;
}
function setText(root,selector,value){const el=root.querySelector(selector);if(el&&el.textContent!==String(value??'')){el.textContent=value??'';}}
function disabled(root,selector,value){root.querySelectorAll(selector).forEach(el=>{el.disabled=!!value;});}
function hidden(root,selector,value){const el=root.querySelector(selector);if(el){el.hidden=!!value;}}
function lobby(app){
 const root=app.root,featured=app.featured;
 const banner=root.querySelector('.ra-banner-slot');
 const prizes=featured?.prizes||[];
 const html=featured?`<div class="ra-season-banner rh-banner"><span class="rh-banner-title"><small>第 ${escape(featured.number)} 赛季</small><strong>${escape(featured.name)}</strong><span>${featured.cadence==='daily'?'每日轮替':'每周轮替'} · 截止 ${escape(app.featuredEnd)}</span></span><span class="rh-banner-metric"><small>前 ${prizes.length} 名 · 奖励总额</small><strong>${prizes.reduce((a,n)=>a+Number(n),0)} <small>RSC</small></strong></span><span class="ra-banner-actions">${button('seasonInfo','奖励详情','ra-banner-detail')}${button('season','去挑战 →','rh-banner-cta')}</span></div>`:`<div class="rh-banner-placeholder">${escape(app.args.catalogError||'')}${app.args.catalogError?button('catalog','重试'):''}</div>`;
 if(app.bannerHTML!==html){banner.innerHTML=html;app.bannerHTML=html;}
 const info=root.querySelector('.ra-season-details');info.hidden=!app.seasonInfo||!featured;
 const infoButton=root.querySelector('[data-action=seasonInfo]');infoButton?.setAttribute('aria-expanded',String(app.seasonInfo));
 if(app.seasonInfo&&featured){const details=`<div class="ra-prize-grid">${prizes.map((p,i)=>`<div><span>第 ${i+1} 名</span><strong>${escape(p)} RSC</strong></div>`).join('')}</div><p>同分平分所占名次奖金；赛季结束后自动到账。</p>`;if(info.innerHTML!==details)info.innerHTML=details;}
 root.querySelectorAll('.ra-featured-tag').forEach(el=>{el.hidden=el.dataset.game!==featured?.game;});
}
function renderArcade(app){
 const root=app.root;
 if(app.layout!==app.game){
  app.stageCleanup?.();app.coverCleanups?.forEach(fn=>fn());app.coverCleanups=[];app.layout=app.game;app.rankHTML=null;app.bannerHTML=null;app.helpHTML=null;
  if(!app.game){
   root.innerHTML=`<div class="ra-banner-slot"></div><div class="ra-season-details" hidden></div><div class="ra-catalog">${app.games.map(g=>`<button type="button" class="ra-card ra-card--${g.color}" data-action="open" data-arg="${g.id}"><div class="ra-card-art" aria-hidden="true"><canvas class="ra-art ra-cover" data-game="${g.id}"></canvas><span class="ra-featured-tag" data-game="${g.id}" hidden>本期挑战</span></div><div class="ra-card-label"><h3>${g.name}</h3><span aria-hidden="true">↗</span></div></button>`).join('')}</div>`;
   root.querySelectorAll('canvas.ra-cover').forEach(c=>app.coverCleanups.push(drawCover(c,c.dataset.game)));
  }else{
   const controls=app.hasControls?`<div class="ra-controls" data-game="${app.game}">${[...app.controlsList,...(app.game==='blocks'?[{key:'drop',label:'落下'}]:[])].map(c=>`<button type="button" data-key="${c.key}" aria-label="${c.label}">${c.label}</button>`).join('')}</div>`:'';
   const sudoku=app.game==='sudoku'?`<div class="ra-sudoku-board"><div class="ra-sudoku-grid" role="grid" aria-label="数独棋盘">${Array.from({length:9},(_,r)=>`<div role="row">${Array.from({length:9},(_,c)=>`<button type="button" role="gridcell" data-cell="${r*9+c}" data-action="cell" data-arg="${r*9+c}"></button>`).join('')}</div>`).join('')}</div><div class="ra-sudoku-complete" role="status" hidden><span aria-hidden="true">✓</span><strong></strong></div></div><div class="ra-sudoku-tools">${button('note','✎ 笔记','btn')}${button('erase','擦除','btn')}${button('undo','撤销','btn')}</div><div class="ra-sudoku-digits">${Array.from({length:9},(_,i)=>button('digit',String(i+1),'',String(i+1))).join('')}</div>`:'';
   const heading=app.fixedGame?'':`<header class="ra-heading">${button('back','← 返回挑战')}<h2>${escape(app.selected.name)}</h2></header>`;
   root.innerHTML=`${heading}<p class="ra-rank-note ra-nonseason" hidden>本局计入总排行；新开一局可参加当前赛季。</p>
    <div class="rg-error" role="alert" hidden><span class="ra-error-text"></span>${button('retry','重试并恢复进度','btn')}${button('recover','读取已保存进度')}</div>
    <div class="ra-layout"><div class="ra-play" data-game="${app.game}"><div class="ra-scorebar"><div><small>本局得分</small><strong>0</strong></div><span role="status">准备就绪</span><small class="ra-progress"></small></div>
    <div class="ra-stage" data-game="${app.game}"><canvas class="ra-canvas" data-game="${app.game}" tabindex="0" role="img" aria-label="${escape(app.selected.name)}"></canvas>${controls}${sudoku}</div>
    <div class="ra-toolbar">${button('start','开始挑战','btn btn-primary ra-start')}${button('pause','暂停并保存','btn')}${button('finish','结束并保存')}</div>
    <details class="ra-rules"><summary>玩法与操作</summary><p>${escape(app.rulesText)}</p><p>允许程序策略，正式成绩以服务器复核为准。后台同步成绩；网络长时间中断时暂停，恢复后继续；存档每次操作后保留 30 天，可暂停后回来继续；赛季结束自动结算已同步的进度，跨期不计入新赛季。</p></details>
    </div><aside class="ra-rank"><div class="ra-rank-heading"><div class="ra-rank-tabs">${button('rank','赛季排行','','season')}${button('rank','总排行','','all')}</div><div class="ra-rank-tools"><button type="button" class="rg-icon-button" data-action="info" aria-label="排行说明" title="排行说明" aria-expanded="false">${icon('info')}</button><button type="button" class="rg-icon-button" data-action="ranking" aria-label="刷新排行" title="刷新排行">${icon('refresh')}</button></div></div><div class="rg-rules ra-rank-help" hidden></div><p class="ra-ranking-error" role="alert" hidden></p><ol></ol></aside></div>`;
   app.stageCleanup=app.attachStage(root.querySelector('.ra-canvas'));
  }
 }
 if(!app.game){lobby(app);return;}
 if(app.game==='sudoku')renderSudoku(app);
 setText(root,'.ra-scorebar div small',app.game==='sudoku'?'已通关':'本局得分');
 hidden(root,'.ra-nonseason',!app.nonSeasonRun);hidden(root,'.rg-error',!app.error);setText(root,'.ra-error-text',app.error);
 disabled(root,'[data-action=back]',app.busy||app.finishing);disabled(root,'[data-action=retry],[data-action=recover]',app.busy||app.syncing);
 setText(root,'.ra-scorebar strong',app.score);setText(root,'.ra-scorebar [role=status]',app.run?app.status:'准备就绪');setText(root,'.ra-progress',app.progressLabel);
 disabled(root,'[data-key]',app.inputDisabled);
 hidden(root,'[data-action=start]',!app.paused&&!app.finished);setText(root,'[data-action=start]',app.startLabel);disabled(root,'[data-action=start]',app.navigationBusy);
 hidden(root,'[data-action=pause]',app.paused||app.finished);disabled(root,'[data-action=pause]',app.busy);
 hidden(root,'[data-action=finish]',!app.run||app.finished);disabled(root,'[data-action=finish]',app.busy||app.finishing);
 hidden(root,'[data-arg=season]',!app.ranking?.season);root.querySelectorAll('.ra-rank-tabs button').forEach(b=>{b.classList.toggle('is-active',b.dataset.arg===app.rankScope);});
 root.querySelector('[data-action=info]').setAttribute('aria-expanded',String(app.rankInfo));hidden(root,'.ra-rank-help',!app.rankInfo);
 const help=`<p>${app.game==='sudoku'?'每人取最高通关数，同关数并列。':'每人取最高分，同分并列。'}</p>${app.rankScope==='season'?`<p>第 ${escape(app.ranking?.season?.number)} 赛季 · 截止 ${escape(app.endLabel)}</p>${app.rankPrizes?`<p>第 1–${escape(app.ranking.season.prizes.length)} 名依次：${escape(app.rankPrizes)} RSC</p><p>同分平分所占名次奖金，结束后自动到账。</p>`:'<p>本期仅排名，不发放 RSC</p>'}`:'<p>历史最高分永久保留。</p>'}`;
 if(app.helpHTML!==help){root.querySelector('.ra-rank-help').innerHTML=help;app.helpHTML=help;}
 hidden(root,'.ra-ranking-error',!app.rankingError);setText(root,'.ra-ranking-error',app.rankingError);
 const rows=app.rankRows,html=rows?.length?rows.map(r=>`<li><span class="ra-place">${escape(r.rank)}</span>${userHTML(r.user)}<strong>${escape(r.score)}${app.game==='sudoku'?' 关':''}</strong></li>`).join(''):'<li class="ra-empty">还没有成绩，来占个位置。</li>';
 if(app.rankHTML!==html){root.querySelector('.ra-rank ol').innerHTML=html;app.rankHTML=html;}
}

function renderSudoku(app){
 const s=app.sudokuCompletion||app.state;if(!s?.board)return;
 const completed=!!app.sudokuCompletion;
 app.root.querySelector('.ra-sudoku-board').classList.toggle('is-complete',completed);
 hidden(app.root,'.ra-sudoku-complete',!completed);
 setText(app.root,'.ra-sudoku-complete strong',completed?`第 ${s.level} 关完成`:'');const selected=app.sudokuCell,value=s.board[selected];
 app.root.querySelectorAll('[data-cell]').forEach(el=>{
  const i=Number(el.dataset.cell),r=Math.floor(i/9),c=i%9,peer=r===Math.floor(selected/9)||c===selected%9||(Math.floor(r/3)===Math.floor(selected/27)&&Math.floor(c/3)===Math.floor(selected%9/3));
  const conflict=!!s.board[i]&&s.board.some((v,j)=>j!==i&&v===s.board[i]&&(Math.floor(j/9)===r||j%9===c||(Math.floor(j/27)===Math.floor(r/3)&&Math.floor(j%9/3)===Math.floor(c/3))));
  el.classList.toggle('is-selected',i===selected);el.classList.toggle('is-peer',peer);el.classList.toggle('is-same',!!value&&s.board[i]===value);el.classList.toggle('is-given',!!s.givens[i]);el.classList.toggle('is-conflict',conflict);
  el.style.setProperty("--cell-wave",`${(r+c)*35}ms`);
  el.tabIndex=i===selected?0:-1;el.setAttribute('aria-selected',String(i===selected));el.setAttribute('aria-readonly',String(!!s.givens[i]));
  el.setAttribute('aria-label',`第 ${r+1} 行第 ${c+1} 列，${s.board[i]||'空格'}${s.givens[i]?'，题目数字':''}${conflict?'，重复冲突':''}`);
  const html=s.board[i]?String(s.board[i]):`<span class="ra-sudoku-notes">${Array.from({length:9},(_,n)=>`<span>${s.notes[i]&(1<<(n+1))?n+1:''}</span>`).join('')}</span>`;
  if(el.innerHTML!==html)el.innerHTML=html;
 });
 const note=app.root.querySelector('[data-action=note]');note.classList.toggle('is-active',app.sudokuNote);note.setAttribute('aria-pressed',String(app.sudokuNote));
 disabled(app.root,'.ra-sudoku-digits button,[data-action=note],[data-action=erase],[data-action=undo]',app.inputDisabled||s.awaiting);
 disabled(app.root,'[data-action=undo]',app.inputDisabled||s.awaiting||!s.history?.length);
}

return {renderArcade};
})();
const {ArcadeApp,GAMES}=(()=>{

const GAMES=[
 {id:'2048',name:'2048',mark:'2048',color:'sand'},
 {id:'blocks',name:'方块堆叠',mark:'▟',color:'lavender'},
 {id:'snake',name:'贪吃蛇',mark:'⌁',color:'mint'},
 {id:'bird',name:'河畔飞鸟',mark:'➤',color:'sky'},
 {id:'hex',name:'六角消除',mark:'⬡',color:'rose'},
 {id:'bricks',name:'打砖块',mark:'▤',color:'peach'},
 {id:'merge',name:'合成大河畔',mark:'🍉',color:'green'},
 {id:'sudoku',name:'数独',mark:'9',color:'lavender'}
];
const ENDLESS_RULES={
 sudoku:'每行、每列及每个九宫格填入 1–9，不能重复。完整填对即进入下一关，按通关数排名，同关数并列。数字键填数，方向键选格，N 切换笔记，Delete 或 Backspace 擦除，Ctrl/Cmd+Z 撤销。笔记只记录候选数，不提供答案。',
 '2048':'方向键或滑动合并相同数字，每次合并累加分数。没有步数和倒计时限制，棋盘无法移动时结束。',
 blocks:'左右移动，上键旋转，下键加速，空格落下。消除 1／2／3／4 行获得 100／300／500／800 分；消行越多下落越快，堆到顶部结束。',
 snake:'方向键或滑动转向，吃到食物获得 100 分。不能直接掉头，撞墙、障碍或身体结束，填满可用格子通关。',
 bird:'轻点画面或空格拍动翅膀。每穿过一道障碍获得 1 分，速度和难度随进度逐步增加，碰撞结束。',
 hex:'左右旋转中心六边形，三个及以上相邻同色块消除，可跨相邻边连接。每三个约 100 分，连续消除有倍数加分；任一边堆到 10 块结束。',
 bricks:'拖动画面或按住键盘左右键移动挡板，每消除一块砖获得 100 分。清屏进入下一关，后续有更耐打的砖块、不同布局和更快球速，3 条生命耗尽结束。',
 merge:'按住拖动选择落点，松手投放；也可左右移动、空格投放。同级图案相碰合成，得分随等级增加。可贴墙投放，越过虚线持续 3 秒结束。'
};
class ArcadeApp {
 games=GAMES;
 rankScope='all';
 rankInfo=false;
 seasonInfo=false;
 sudokuCompletion=null;
 sudokuCompletedLevel=null;
 clearSudokuCompletion(){clearTimeout(this.sudokuCompletionTimer);this.sudokuCompletion=null;this.scheduleRender();}
 observeSudokuCompletion(state){
  if(this.game!=='sudoku'||!state.awaiting||this.sudokuCompletedLevel===state.level)return;
  this.sudokuCompletedLevel=state.level;
  this.sudokuCompletion=structuredClone(state);
  clearTimeout(this.sudokuCompletionTimer);
  this.sudokuCompletionTimer=setTimeout(()=>{this.sudokuCompletion=null;this.scheduleRender();},1800);
 }
 sudokuCell=0;
 sudokuNote=false;
 sudokuSelect(i){this.sudokuCell=Number(i);this.scheduleRender();}
 sudokuWrite(n){this.input(`${this.sudokuNote?'n':'v'}:${this.sudokuCell}:${n}`);}
 sudokuKey(e){
  if(this.game!=='sudoku'||e.isComposing||e.altKey||e.target.closest('input,textarea,select'))return;
  const k=e.key.toLowerCase(),dirs={arrowleft:-1,a:-1,arrowright:1,d:1,arrowup:-9,w:-9,arrowdown:9,s:9};
  if((e.ctrlKey||e.metaKey)&&k==='z'){e.preventDefault();this.input('undo');return;}
  if(e.ctrlKey||e.metaKey)return;
  if(k in dirs){e.preventDefault();this.sudokuSelect(Math.max(0,Math.min(80,this.sudokuCell+dirs[k])));this.root.querySelector(`[data-cell="${this.sudokuCell}"]`)?.focus({preventScroll:true});}
  else if(/^[1-9]$/.test(k)){e.preventDefault();this.sudokuWrite(k);}
  else if(['backspace','delete','0'].includes(k)){e.preventDefault();this.input(`v:${this.sudokuCell}:0`);}
  else if(k==='n'){e.preventDefault();this.sudokuNote=!this.sudokuNote;this.scheduleRender();}
 }
 toggleRankInfo(){this.rankInfo=!this.rankInfo;}
 rankChosen=false;
 game=null;
 run=null;
 busy=false;
 paused=true;
 error='';
 ranking=null;
 rankingError='';
 score=0;
 progress=0;
 pending=null;
 syncing=false;
 finishing=false;
 waiting=false;
 localOver=false;
 effects=new Effects();repaint=true;mergeSprites=null;
 playback=null;state=null;canvas=null;raf=null;last=0;accumulator=0;generation=0;
 syncPromise=null;saveRequested=false;lastInputAt=0;
 get fixedGame(){return this.args.embedded&&this.args.game;}
 get selected(){return GAMES.find(g=>g.id===this.game);}
 get rulesVersion(){return Core.version;}
 get rulesText(){
  const keyboard=['2048','blocks','snake','sudoku'].includes(this.game)?'方向键也可使用 WASD。':['hex','bricks','merge'].includes(this.game)?'左右键也可使用 A／D。':'';
  return `${ENDLESS_RULES[this.game]} ${keyboard}Esc 暂停并保存。`;
 }
 get grid(){return this.game==='2048';}
 get turnBased(){return this.grid||this.game==='sudoku';}
 get finished(){return this.run?.status==='finished';}
 get inputDisabled(){return this.paused||this.busy||this.finishing||this.finished||this.localOver||!!this.sudokuCompletion;}
 get navigationBusy(){return this.busy||this.syncing||!!this.pending;}
 get endLabel(){return this.ranking?.season?.ends_at?formatDateTime(this.ranking.season.ends_at):'';}
 get featured(){return this.args.catalog?.current;}
 get featuredEnd(){return this.featured?formatDateTime(this.featured.ends_at):'';}
 get featuredPrizes(){return this.featured?.prizes?.slice(0,5).join(' / ') || '';}
 get rankPrizes(){return this.ranking?.season?.prizes?.join(' / ') || '';}
 get rankRows(){return this.rankScope==='season'?this.ranking?.season?.rows:this.ranking?.rows;}
 get nonSeasonRun(){return this.run&&this.ranking?.season&&this.run.season_id!==this.ranking.season.id;}
 selectRank(scope){this.rankScope=scope;this.rankChosen=true;}
 openSeason(){if(this.featured){this.open(this.featured.game);this.rankScope='season';}}
 get status(){return this.finished?'成绩已保存':this.error?'连接中断':this.sudokuCompletion?'本关完成':this.finishing||this.localOver?'保存成绩':this.paused?'已暂停':this.waiting?'等待同步':'挑战中';}
 get startLabel(){return this.finished?'再来一局':this.run?'继续挑战':'开始挑战';}
 get progressLabel(){if(!this.state){return '';}if(this.grid){return `${this.progress} 步`;}if(this.game==='sudoku'){return `第 ${this.sudokuCompletion?.level||this.state.level||1} 关`;}if(this.game==='blocks'){return `${this.state.lines} 行`;}if(this.game==='merge'){return `${this.state.drops} 次投放`;}if(this.game==='bricks'){return `第 ${this.state.wave||1} 关`;}if(this.game==='bird'){return `${this.score} 道障碍`;}return '';}
 get controls(){return ['blocks','snake'].includes(this.game)?['u','l','d','r']:this.game==='hex'?['l','r']:[];}
 get hasControls(){return ['blocks','snake','hex'].includes(this.game);}
 focusPlay(){if(this.game==='sudoku'){this.root.querySelector(`[data-cell="${this.sudokuCell}"]`)?.focus({preventScroll:true});return;}this.canvas?.focus({preventScroll:true});if(window.innerWidth<=767){this.canvas?.closest('.ra-play')?.scrollIntoView({block:'start',behavior:'instant'});}}
 get controlsList(){return this.controls.map(k=>({key:k,label:{l:'←',r:'→',u:'↑',d:'↓'}[k]}));}
 async open(game){
  if(this.fixedGame&&game!==this.args.game){return;}
  this.clearSudokuCompletion();this.sudokuCompletedLevel=null;
  this.generation++;this.rankInfo=false;this.rankChosen=false;this.rankScope=this.featured?.game===game?'season':'all';this.game=game;this.run=null;this.playback=null;this.pending=null;this.error='';
  this.paused=true;this.finishing=false;this.waiting=false;this.localOver=false;this.saveRequested=false;this.ranking=null;
  this.effects=new Effects({reducedMotion:window.matchMedia('(prefers-reduced-motion: reduce)').matches});this.state=Core.create(game,Array(24).fill(3733),this.rulesVersion);this.effects.observe(this.state);this.score=0;this.progress=0;this.loadRanking();
  if(game==='merge'){loadMergeSprites().then(images=>{if(!this.isDestroying){this.mergeSprites=images;this.effects.sprites=images;this.repaint=true;}});}
 }
 async back(){
  if(this.fixedGame){return;}
  if(this.busy||this.finishing){return;}this.paused=true;this.playback?.release();await this.flush();
  if(!this.error&&!this.isDestroying){this.clearSudokuCompletion();this.startKey=null;this.game=null;this.playback=null;this.generation++;}
 }
 async loadRanking(){const game=this.game;this.rankingError='';try{const r=await this.request('ranking',{game});if(this.game===game&&!this.isDestroying){this.ranking=r;this.args.updateSeason?.(r.featured);if(!this.rankChosen){this.rankScope=r.season?'season':'all';}else if(!r.season){this.rankScope='all';}}}catch(e){if(!this.isDestroying){this.rankingError=this.errorText(e);}}}
 start(){
  if(this.startPromise){return this.startPromise;}
  this.startPromise=this.startRun().finally(()=>{this.startPromise=null;});return this.startPromise;
 }
 async startRun(){
  if(this.busy||this.syncing||this.pending){return;}
  if(this.run?.status==='playing'&&!this.error){this.hostPaused=false;this.paused=false;this.focusPlay();return;}
  this.hostPaused=false;this.busy=true;this.error='';const generation=this.generation;
  try{
   const r=await this.request('start',{game:this.game,request_id:this.startKey ||= crypto.randomUUID(),rules_version:this.rulesVersion,scope:this.rankScope});
   if(this.isDestroying||generation!==this.generation){return;}
   this.effects=new Effects({reducedMotion:window.matchMedia('(prefers-reduced-motion: reduce)').matches});this.effects.sprites=this.mergeSprites;this.clearSudokuCompletion();this.sudokuCompletedLevel=null;this.playback=new Playback(r);this.finishing=false;this.saveRequested=false;this.updateView();
   this.startKey=null;this.paused=this.hostPaused||r.status!=='playing';this.focusPlay();
  }catch(e){if(!this.isDestroying){this.error=this.errorText(e);}}
  finally{if(!this.isDestroying){this.busy=false;}}
 }
 updateView(){
  const p=this.playback;if(!p){return;}
  this.observeSudokuCompletion(p.state);
  this.run=p.run;this.state=p.state;this.pending=p.pending;this.score=p.state.score;
  if(this.turnBased||p.state.tick%15===0||p.state.over){this.progress=p.state.tick;}
  this.waiting=p.blocked&&!p.state.over;this.localOver=p.state.over;this.effects.observe(p.state,p.visualMove);this.repaint=true;if(this.game==='sudoku')this.scheduleRender();
 }
 paint(){if(this.canvas&&this.state){draw(this.canvas,this.state,this.effects);}}
 async pause(){this.hostPaused=true;this.paused=true;this.playback?.release();await this.startPromise;this.paused=true;this.playback?.release();await this.flush();}
 async finish(){this.clearSudokuCompletion();this.paused=true;this.playback?.release();if(this.playback){this.playback.keys=[];}await this.flush(true);}
 recover(){
  if(this.busy||this.syncing){return;}
  this.pending=null;this.playback=null;this.run=null;this.startKey=null;this.finishing=false;this.error='';return this.start();
 }
 async retry(){
  if(this.busy||this.syncing){return;}
  if(!this.playback){return this.start();}
  this.error='';await this.flush();
  if(!this.error&&!this.finished&&!this.isDestroying){this.paused=false;}
 }
 flush(finish=false){
  if(!this.playback||this.run.status!=='playing'){return Promise.resolve();}
  if(finish){this.finishing=true;}
  this.saveRequested=true;
  if(this.syncPromise){return this.syncPromise;}
  if(this.busy||this.error){return Promise.resolve();}
  if(!this.playback.pending&&!this.playback.frames&&!this.finishing){this.saveRequested=false;return Promise.resolve();}
  this.syncPromise=this.sendLoop();return this.syncPromise;
 }
 async sendLoop(){
  const p=this.playback;this.syncing=true;
  try{
   while(!this.isDestroying&&p===this.playback&&p.run.status==='playing'){
    if(!p.pending){
     if(!this.saveRequested&&!this.finishing&&!p.needsSync&&!(this.paused&&p.frames)){break;}
     p.checkpoint(crypto.randomUUID(),this.finishing);this.saveRequested=false;
    }
    if(!p.pending){break;}
    this.pending=p.pending;
    const r=await this.request('advance',{id:p.run.id,...p.pending,rules_version:this.rulesVersion});
    if(this.isDestroying||p!==this.playback){return;}
    p.acknowledge(r);this.updateView();
    if(r.status!=='playing'){this.paused=true;this.finishing=false;this.loadRanking();break;}
    // Consume queued gestures after a refill, without waiting between moves.
    if(this.turnBased&&!this.paused){p.advance();this.updateView();}
   }
  }catch(e){
   if(!this.isDestroying){this.error=this.errorText(e);this.paused=true;p.release();}
  }finally{if(!this.isDestroying){this.syncing=false;this.syncPromise=null;}}
 }
 input(key){
  if(!this.playback||this.inputDisabled||this.error){return;}
  this.lastInputAt=performance.now();this.playback.input(key);if(this.turnBased){this.advanceFrame();}
 }
 press(key,e){
  e?.preventDefault();if(this.inputDisabled){return;}
  e?.currentTarget?.setPointerCapture?.(e.pointerId);
  this.canvas?.focus({preventScroll:true});this.input(key);this.playback?.hold(key);
 }
 release(key){this.playback?.release(key);}
 keyboardPress(key,e){if(e.detail===0){this.input(key);}}
 dropPress(e){this.press('drop',e);}
 dropKeyboard(e){if(e.detail===0){this.input('drop');}}
 advanceFrame(){
  const p=this.playback;if(!p){return;}
  if(p.advance()){this.updateView();}
  if(p.needsSync){this.flush();}
 }
 attachStage(canvas){
  this.canvas=canvas;this.paint();let pointer=null;
  const keyMap={ArrowLeft:'l',ArrowRight:'r',ArrowUp:'u',ArrowDown:'d',a:'l',d:'r',w:'u',s:'d',' ':'drop'};
  const mapped=e=>keyMap[e.key]||keyMap[e.key?.toLowerCase()];
  const escape=e=>{
   if(e.key!=='Escape'||e.repeat||e.isComposing||e.ctrlKey||e.metaKey||e.altKey||e.target.closest?.('input,textarea,select,[contenteditable="true"]')){return;}
   if(this.run?.status==='playing'&&!this.paused&&!this.finishing){e.preventDefault();e.stopPropagation();this.pause();}
  };
  const key=e=>{
   if(e.isComposing||e.ctrlKey||e.metaKey||e.altKey){return;}
   if(this.game==='sudoku')return;const k=mapped(e);if(!k){return;}e.preventDefault();
   if(!e.repeat&&!this.inputDisabled){this.input(this.game==='bird'?'tap':k);this.playback?.hold(k);}
  };
  const up=e=>{const k=mapped(e);if(k){this.playback?.release(k);}};
  const aim=e=>{const r=canvas.getBoundingClientRect();return `x:${Math.round(Math.max(0,Math.min(4000,(e.clientX-r.left)/r.width*4000)))}`;};
  const down=e=>{
   if(pointer||this.inputDisabled){return;}e.preventDefault();canvas.setPointerCapture(e.pointerId);pointer={id:e.pointerId,x:e.clientX,y:e.clientY,swiped:false};canvas.focus({preventScroll:true});
   if(this.game==='bricks'&&this.rulesVersion>=2){this.input(aim(e));}else if(this.game==='merge'){this.input(aim(e));}
  };
  const playArea=canvas.closest('.ra-play');
  const flap=e=>{if(this.game!=='bird'||this.inputDisabled||e.target.closest('button,a,input,summary,details')){return;}e.preventDefault();canvas.focus({preventScroll:true});this.input('tap');};
  playArea.addEventListener('pointerdown',flap);
  const swipe=e=>{
   if(pointer&&pointer.id===e.pointerId&&!pointer.swiped&&(this.grid||this.game==='snake')){const dx=e.clientX-pointer.x,dy=e.clientY-pointer.y;if(Math.max(Math.abs(dx),Math.abs(dy))>15){pointer.swiped=true;this.input(Math.abs(dx)>Math.abs(dy)?dx>0?'r':'l':dy>0?'d':'u');}}
  };
  const end=e=>{
   if(!pointer||pointer.id!==e.pointerId){return;}swipe(e);
   if(this.game==='merge'&&!this.inputDisabled){this.input(aim(e));this.input('drop');}
   pointer=null;
  };
  const cancel=()=>{pointer=null;this.playback?.release();};
  const move=e=>{swipe(e);if((!pointer||pointer.id===e.pointerId)&&(this.game==='merge'||(pointer&&this.game==='bricks'&&this.rulesVersion>=2))){this.input(aim(e));}};
  const blur=()=>{cancel();this.pause();};const visibility=()=>{if(document.hidden){cancel();this.pause();}};
  this.root.addEventListener('keydown',escape);canvas.addEventListener('keydown',key);window.addEventListener('keyup',up);canvas.addEventListener('pointerdown',down);canvas.addEventListener('pointerup',end);canvas.addEventListener('pointercancel',cancel);canvas.addEventListener('pointermove',move);window.addEventListener('blur',blur);document.addEventListener('visibilitychange',visibility);
  const loop=t=>{
   if(this.isDestroying){return;}const delta=Math.min(100,t-(this.last||t));this.last=t;
   if(!this.inputDisabled&&!this.error&&this.run?.status==='playing'){
    if(this.turnBased){this.advanceFrame();if(this.playback.frames&&!this.syncing&&t-this.lastInputAt>=(this.game==='sudoku'?1500:250)){this.flush();}}else{
     this.accumulator+=delta;let count=0;
     while(this.accumulator>=1000/60&&count++<6){
      this.advanceFrame();this.accumulator-=1000/60;
      if(this.playback.blocked||this.state.over){this.accumulator=0;break;}
     }
    }
   }else{this.accumulator=0;}
   if(this.repaint||this.effects.active()){this.paint();this.repaint=false;}this.raf=requestAnimationFrame(loop);
  };this.raf=requestAnimationFrame(loop);
  return()=>{this.root.removeEventListener('keydown',escape);playArea.removeEventListener('pointerdown',flap);cancelAnimationFrame(this.raf);canvas.removeEventListener('keydown',key);window.removeEventListener('keyup',up);canvas.removeEventListener('pointerdown',down);canvas.removeEventListener('pointerup',end);canvas.removeEventListener('pointercancel',cancel);canvas.removeEventListener('pointermove',move);window.removeEventListener('blur',blur);document.removeEventListener('visibilitychange',visibility);this.canvas=null;this.playback?.release();};
 }

 constructor(root,options){
  this.root=root;this.args=options;this.request=options.request;this.startKey=null;this.hostPaused=false;
  this.errorText=options.errorText||((e)=>e?.message||'网络连接中断，请重试或读取已保存进度。');
  for(const name of ['rankScope','rankInfo','game','run','busy','paused','error','ranking','rankingError','score','progress','pending','syncing','finishing','waiting','localOver']){
   let value=this[name];Object.defineProperty(this,name,{get:()=>value,set:(next)=>{if(value!==next){value=next;this.scheduleRender();}}});
  }
  this.click=(e)=>{const b=e.target.closest('[data-action]');if(!b||!root.contains(b)||b.disabled){return;}
   const action=b.dataset.action,arg=b.dataset.arg;
   if(action==='profile'){if(options.onProfile){e.preventDefault();options.onProfile(arg);}return;}
   const actions={seasonInfo:()=>{this.seasonInfo=!this.seasonInfo;this.scheduleRender();},cell:()=>this.sudokuSelect(arg),digit:()=>this.sudokuWrite(arg),note:()=>{this.sudokuNote=!this.sudokuNote;this.scheduleRender();},erase:()=>this.input(`v:${this.sudokuCell}:0`),undo:()=>this.input('undo'),open:()=>this.open(arg),back:()=>this.back(),start:()=>this.start(),pause:()=>this.pause(),finish:()=>this.finish(),retry:()=>this.retry(),recover:()=>this.recover(),rank:()=>this.selectRank(arg),info:()=>this.toggleRankInfo(),ranking:()=>this.loadRanking(),season:()=>this.openSeason(),catalog:()=>options.reloadCatalog?.()};
   if(actions[action]){Promise.resolve(actions[action]()).catch(error=>{this.error=this.errorText(error);});}
  };
  this.pointerDown=(e)=>{const b=e.target.closest('[data-key]');if(b&&root.contains(b)){this.press(b.dataset.key,{preventDefault:()=>e.preventDefault(),currentTarget:b,pointerId:e.pointerId});}};
  this.pointerUp=(e)=>{const b=e.target.closest('[data-key]');if(b){this.release(b.dataset.key);}};
  this.keyClick=(e)=>{const b=e.target.closest('[data-key]');if(b&&e.detail===0){this.input(b.dataset.key);}};
  this.sudokuKeyboard=e=>this.sudokuKey(e);root.addEventListener('keydown',this.sudokuKeyboard);root.addEventListener('click',this.click);root.addEventListener('click',this.keyClick);root.addEventListener('pointerdown',this.pointerDown);
  for(const event of ['pointerup','pointercancel','lostpointercapture']){root.addEventListener(event,this.pointerUp);}
  this.render();if(options.game&&GAMES.some(g=>g.id===options.game)){this.open(options.game);}
 }
 scheduleRender(){if(this.renderQueued||this.isDestroying||this.closing){return;}this.renderQueued=true;queueMicrotask(()=>{this.renderQueued=false;if(!this.isDestroying&&!this.closing){this.render();}});}
 render(){renderArcade(this);}
 update(options){Object.assign(this.args,options);this.scheduleRender();}
 async saveForHost(){
  await this.pause();
  if(this.error&&this.playback){this.error='';await this.flush();}
  this.paused=true;this.playback?.release();
  const saved=!this.busy&&!this.syncing&&!this.pending&&!this.playback?.frames&&!this.error;
  return {saved,run_id:this.run?.id||null,version:this.run?.version??null,status:this.run?.status||null,...(!saved?{error:this.error||'进度尚未同步，请重试保存。'}:{})};
 }
 async resumeForHost(){
  // Never discard an unacknowledged request or invent a new request ID.
  if(this.pending||this.playback?.frames){const saved=await this.saveForHost();if(!saved.saved){return saved;}}
  if(this.game&&this.run?.status==='playing'){
   this.run=null;this.playback=null;
   const started=this.start();this.hostPaused=true;await started;
  }
  this.paused=true;return {saved:!this.error,run_id:this.run?.id||null,version:this.run?.version??null,...(this.error?{error:this.error}:{})};
 }
 destroy(){
  this.clearSudokuCompletion();this.closing=true;this.stageCleanup?.();this.coverCleanups?.forEach(fn=>fn());
  this.root.removeEventListener('keydown',this.sudokuKeyboard);this.root.removeEventListener('click',this.click);this.root.removeEventListener('click',this.keyClick);this.root.removeEventListener('pointerdown',this.pointerDown);
  for(const event of ['pointerup','pointercancel','lostpointercapture']){this.root.removeEventListener(event,this.pointerUp);}
  return this.pause().finally(()=>{this.isDestroying=true;this.generation++;});
 }
}

return {ArcadeApp,GAMES};
})();
const {arcadeRequest}=(()=>{
const games=['2048','blocks','snake','bird','hex','bricks','merge','sudoku'];
const fail=()=>{throw new Error('无效的游戏请求');};
// Also supplied to native implementers as the exact API allowlist contract.
function arcadeRequest(action,payload={}){
 if(!payload||typeof payload!=='object'||Array.isArray(payload)){fail();}
 if(action==='catalog'){return {method:'GET',path:'/rsc/arcade/catalog.json'};}
 if(action==='ranking'){
  if(!games.includes(payload.game)){fail();}
  return {method:'GET',path:'/rsc/arcade/ranking.json?game='+encodeURIComponent(payload.game)};
 }
 if(!['start','advance'].includes(action)){fail();}
 if(typeof payload.request_id!=='string'||payload.request_id.length<1||payload.request_id.length>100||![2,3,4].includes(payload.rules_version)){fail();}
 if(action==='start'){
  if(!games.includes(payload.game)||!['all','season'].includes(payload.scope)){fail();}
  const {game,request_id,rules_version,scope}=payload;
  return {method:'POST',path:'/rsc/arcade/start.json',body:{game,request_id,rules_version,scope}};
 }
 const {id,version,request_id,rules_version,frames,events,finish}=payload;
 if(!Number.isSafeInteger(id)||id<=0||!Number.isSafeInteger(version)||version<0||!Number.isInteger(frames)||frames<0||frames>180||!Array.isArray(events)||events.length>360||typeof finish!=='boolean'){fail();}
 if(!events.every(e=>Array.isArray(e)&&e.length===2&&Number.isInteger(e[0])&&e[0]>=0&&e[0]<frames&&typeof e[1]==='string'&&/^(l|r|u|d|drop|tap|x:(?:[0-9]{1,4})|[vn]:[0-9]{1,2}:[0-9]|undo)$/.test(e[1])&&(!e[1].startsWith('x:')||Number(e[1].slice(2))<=4000))){fail();}
 return {method:'POST',path:`/rsc/arcade/${id}/advance.json`,body:{version,request_id,rules_version,frames,events,finish}};
}

return {arcadeRequest};
})();
const ArcadeBridge=(()=>{
const BRIDGE_PROTOCOL=1;
const BRIDGE_CHANNEL='riverside.arcade';
// No cookies, credentials, arbitrary URLs or request headers cross this bridge.
class ArcadeBridge {
 constructor({send,onInit,onCommand,onError=()=>{},timeout=15000}){
  this.session=crypto.randomUUID();this.send=send;this.onInit=onInit;this.onCommand=onCommand;this.onError=onError;this.timeout=timeout;
  this.pending=new Map();this.commands=new Map();this.initialized=false;this.closed=false;this.commandTail=Promise.resolve();
 }
 emit(message){if(!this.closed){this.send({channel:BRIDGE_CHANNEL,protocol:BRIDGE_PROTOCOL,session:this.session,...message});}}
 ready(){this.emit({type:'ready',rules_version:Core.version,actions:['catalog','ranking','start','advance'],commands:['pause','resume','exit','theme']});}
 receive(raw){
  let message;try{if(typeof raw==='string'&&raw.length>1048576){return;}message=typeof raw==='string'?JSON.parse(raw):raw;}catch{return;}
  if(this.closed||!message||message.channel!==BRIDGE_CHANNEL||message.protocol!==BRIDGE_PROTOCOL||message.session!==this.session){return;}
  if(message.type==='init'){
   if(this.initialized){return;}this.initialized=true;
   this.emit({type:'initialized',rules_version:Core.version});
   Promise.resolve(this.onInit(message.payload||{})).catch(e=>this.onError(e));return;
  }
  if(!this.initialized){return;}
  if(message.type==='response'){
   const p=this.pending.get(message.id);if(!p){return;}this.pending.delete(message.id);clearTimeout(p.timer);
   if(message.error){const e=new Error(typeof message.error.message==='string'?message.error.message:'游戏请求失败，请重试。');e.code=message.error.code;e.status=message.error.status;p.reject(e);}else{p.resolve(message.result);}return;
  }
  if(message.type==='command'&&typeof message.id==='string'&&message.id.length<=100&&['pause','resume','exit','theme'].includes(message.action)){
   const key=message.id,signature=JSON.stringify([message.action,message.payload||{}]);
   const prior=this.commands.get(key);
   if(prior){if(prior.signature===signature){prior.result.then(result=>this.emit({type:'command-result',id:key,...result}));}return;}
   if(this.commands.size>=64){this.commands.delete(this.commands.keys().next().value);}
   const result=this.commandTail.then(()=>this.onCommand(message.action,message.payload||{})).then(result=>({result})).catch(e=>({error:{message:e.message||'操作失败，请重试。'}}));
   this.commandTail=result;this.commands.set(key,{signature,result});result.then(value=>this.emit({type:'command-result',id:key,...value}));
  }
 }
 request(action,payload={}){
  if(!this.initialized||this.closed){return Promise.reject(new Error('游戏连接尚未就绪'));}
  arcadeRequest(action,payload); // Validate before sending to the host; host MUST validate independently.
  if(this.pending.size>=8){return Promise.reject(new Error('请求仍在处理中，请稍后重试'));}
  const id=crypto.randomUUID();
  return new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('网络连接超时，请重试原请求或读取已保存进度。'));},this.timeout);
   this.pending.set(id,{resolve,reject,timer});
   try{this.emit({type:'request',id,action,payload});}catch(e){clearTimeout(timer);this.pending.delete(id);reject(e);}
  });
 }
 close(){this.closed=true;for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(new Error('游戏页面已关闭'));}this.pending.clear();}
}

return ArcadeBridge;
})();

// This is a public UI shell. Every operation is authenticated by the native host
// and independently checked by the existing RSC API; this page grants no access.
const root=document.getElementById('arcade'),status=document.getElementById('connection');
const params=new URLSearchParams(location.search),mode=params.get('mode')||'native';
let app=null,retired=false,catalogPromise=null;
function showError(error){status.textContent=error?.message||'游戏暂时无法连接';status.hidden=false;}
function theme(value){document.documentElement.dataset.theme=['light','dark'].includes(value)?value:'auto';}
const send=(message)=>{
 if(mode==='iframe'){
  if(window.parent===window){throw new Error('请从 App 打开游戏');}
  window.parent.postMessage(message,location.origin);
 }else if(mode==='native'){
  if(typeof window.RiversideArcadeChannel?.postMessage==='function'){window.RiversideArcadeChannel.postMessage(JSON.stringify(message));}
 }else{throw new Error('不支持的嵌入模式');}
};
const bridge=new ArcadeBridge({send,onError:showError,onInit:async payload=>{
 clearInterval(readyTimer);theme(payload.theme);status.hidden=true;
 const game=params.get('game');if(game&&!GAMES.some(g=>g.id===game)){throw new Error('未找到这个游戏');}
 app=new ArcadeApp(root,{game,embedded:true,request:(action,data)=>{if(retired){throw new Error('游戏已退出，请重新打开');}return bridge.request(action,data);},reloadCatalog:()=>loadCatalog(),
  updateSeason:current=>{if(current){app.update({catalog:{...app.args.catalog,current}});}},
  onProfile:username=>bridge.emit({type:'profile',username})});
 await loadCatalog();
},onCommand:async(action,payload)=>{
 if(!app){throw new Error('游戏尚未就绪');}
 if(retired&&action!=='exit'){throw new Error('游戏已退出，请重新打开');}
 if(action==='theme'){theme(payload.theme);return {ok:true};}
 if(action==='resume'){return app.resumeForHost();}
 const result=await app.saveForHost();
 if(action==='exit'&&result.saved){retired=true;root.inert=true;}
 return result;
}});
async function loadCatalog(){
 if(catalogPromise){return catalogPromise;}
 catalogPromise=(async()=>{
  try{const catalog=await bridge.request('catalog');if(catalog.rules_version!==Core.version){throw new Error('游戏规则已更新，请重新进入游戏。');}app.update({catalog,catalogError:''});}
  catch(e){app.update({catalogError:e.message});}
  finally{catalogPromise=null;}
 })();return catalogPromise;
}
// Native host must only invoke this function for this trusted main document.
Object.defineProperty(window,'RiversideArcadeHost',{value:Object.freeze({receive:message=>{if(mode==='native'){bridge.receive(message);}}}),writable:false});
window.addEventListener('message',event=>{if(mode==='iframe'&&event.source===window.parent&&event.origin===location.origin){bridge.receive(event.data);}});
window.addEventListener('pagehide',()=>{app?.pause();});
window.addEventListener('pageshow',e=>{if(e.persisted&&app&&!retired){app.resumeForHost();}});
const readyTimer=setInterval(()=>{try{bridge.ready();}catch(e){showError(e);}},1000);
try{bridge.ready();}catch(e){showError(e);}

})();
