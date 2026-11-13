// Shared deterministic rules. No clock, browser API, random seed or wallet access.
// All coordinates and velocities are integers. Rendering never affects simulation.
const ARCADE_VERSION = 6;
const GAME_IDS = ["2048", "blocks", "snake", "bird", "hex", "bricks", "merge", "sudoku"];
const LIMITS = {"2048": 2000, blocks: 18000, snake: 18000, bird: 10800, hex: 10800, bricks: 18000, merge: 18000};
const SHAPES = [[[0,0],[1,0],[2,0],[3,0]],[[0,0],[1,0],[0,1],[1,1]],[[1,0],[0,1],[1,1],[2,1]],[[1,0],[2,0],[0,1],[1,1]],[[0,0],[1,0],[1,1],[2,1]],[[0,0],[0,1],[1,1],[2,1]],[[2,0],[0,1],[1,1],[2,1]]];
const RADIUS = [110,145,185,235,295,365,445,535,635,745,865];
const clone = (s) => JSON.parse(JSON.stringify(s));
function take(s,n) { if (!s.q.length) { throw new Error("queue_empty"); } return s.q.shift()%n; }
function tile(s) { const empty=s.board.map((v,i)=>v?null:i).filter(i=>i!==null); if(empty.length){s.board[empty[take(s,empty.length)]]=take(s,10)===0?4:2;} }
function food(s) { const free=[];for(let i=0;i<400;i++){if(!s.snake.includes(i)&&!s.walls.includes(i)){free.push(i);}}if(!free.length){s.over=true;}else{s.food=free[take(s,free.length)];} }
function drawShape(s){
 if(!s.bag?.length)s.bag=[0,1,2,3,4,5,6];
 return s.bag.splice(take(s,s.bag.length),1)[0];
}
function spawnShape(s,shape){
 s.piece={cells:shape===0?[[0,1],[1,1],[2,1],[3,1]]:clone(SHAPES[shape]),shape,rotation:0,x:3,y:0,color:shape+1};
 s.fall=0;if(s.version>=6)s.gravityUnits=0;s.lock=0;s.lockResets=0;if(!fits(s,s.piece))s.over=true;
}
function block(s) {
 if(s.version>=5){
  const shape=s.nextShape??drawShape(s);s.nextShape=drawShape(s);
  spawnShape(s,shape);s.pieces++;s.heldThisPiece=false;return;
 }
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
   const prev=s.history.pop();if(prev){if(prev.board){s.board=prev.board;s.notes=prev.notes;}else{s.board[prev[0]]=prev[1];s.notes[prev[0]]=prev[2];for(const [j,n] of prev[3]||[])s.notes[j]=n;}}continue;
  }
  if(key==='reset'){s.history.push({board:s.board.slice(),notes:s.notes.slice()});if(s.history.length>200)s.history.shift();s.board=s.givens.slice();s.notes=Array(81).fill(0);continue;}
  const m=/^([vn]):([0-9]{1,2}):([0-9])$/.exec(key);if(!m)continue;
  const i=Number(m[2]),v=Number(m[3]);if(i>80||s.givens[i])continue;
  const previous=[i,s.board[i],s.notes[i]];
  if(m[1]==='n'){if(v&& !s.board[i])s.notes[i]^=1<<v;}
  else{if(v&&s.board[i]!==v&&s.board.filter(n=>n===v).length>=9)continue;s.board[i]=v;s.notes[i]=0;previous[3]=[];if(v)for(const j of sudokuPeers[i])if(s.notes[j]&(1<<v)){previous[3].push([j,s.notes[j]]);s.notes[j]&=~(1<<v);}}
  if(previous[1]!==s.board[i]||previous[2]!==s.notes[i]||previous[3]?.length){s.history.push(previous);if(s.history.length>200)s.history.shift();}
  if(sudokuValid(s.board)){s.score++;s.awaiting=true;s.history=[];break;}
 }
}

function create(game,q,version=ARCADE_VERSION) {
 if(![1,2,3,4,5,6].includes(version)){throw new Error("rules_version");}
 if(!GAME_IDS.includes(game)){throw new Error("game");}
 const s={game,version,tick:0,score:0,over:false,q:q.slice(),limit:version===1?LIMITS[game]:null};
 if(game==="sudoku"){sudokuLoad(s,'530070000600195000098000060800060003400803001700020006060000280000419005000080079'.split('').map(Number));s.awaiting=true;}
 if(game==="2048"){s.board=Array(16).fill(0);tile(s);tile(s);}
 if(game==="blocks"){s.board=Array(200).fill(0);s.lines=0;s.pieces=0;block(s);}
 if(game==="snake"){s.snake=[210,209,208];s.dir=1;s.walls=[84,85,86,87,312,313,314,315];food(s);}
 if(game==="bird"){s.y=2500;s.vy=0;s.pipes=[];s.next=0;}
 if(game==="hex"){s.lanes=Array.from({length:6},()=>[]);s.rotation=0;s.falling=null;}
 if(game==="bricks"){s.x=2000;s.y=4700;s.vx=27;s.vy=-36;s.paddle=2000;s.lives=3;s.board=Array(48).fill(1);if(version>=2){s.wave=1;}if(version>=5)s.board=brickLayout(1,version);}
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
 s.board=brickLayout(s.wave,s.version);
 s.x=s.paddle;s.y=4700;s.vx=27;s.vy=-Math.min(65,36+(s.wave-1)*3);
 delete s.target;
}
function brickLayout(wave,version){
 return Array.from({length:48},(_,i)=>{
  const row=Math.floor(i/8),col=i%8;
  const gap=version>=5?[row%2===1&&col%3===1,Math.abs(col-3.5)+row>6,row>1&&col>1&&col<6,(row+col)%3===0][(wave-1)%4]:wave%3===2?(row+col)%7===0:wave%3===0?row%2===1&&col%3===1:false;
  return gap?0:Math.min(3,1+Math.floor((wave-1)/3)+(row<2?0:-1))||1;
 });
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
 if(s.version>=5&&s.nextShape===undefined)s.nextShape=drawShape(s);
 if(s.version>=5&&keys.includes('x:0')&&!s.heldThisPiece){
  const shape=s.piece.shape,held=s.holdShape;
  if(shape!==undefined){s.holdShape=shape;if(held===undefined)block(s);else spawnShape(s,held);s.heldThisPiece=true;return;}
 }
 let adjusted=false;
 if(keys.includes('l')||keys.includes('r')){const next={...s.piece,x:s.piece.x+(keys.includes('l')?-1:1)};if(fits(s,next)){s.piece=next;adjusted=true;}}
 if(keys.includes('u')||(s.version>=5&&keys.includes('tap'))){
  const reverse=s.version>=5&&keys.includes('tap')&&!keys.includes('u');
  const current=s.piece,orientation=current.rotation||0,pivot=current.shape===0?1.5:current.shape===1?.5:1;
  const cells=current.shape===undefined?current.cells.map(([x,y])=>[-y,x]):current.cells.map(([x,y])=>reverse?[pivot+(y-pivot),pivot-(x-pivot)]:[pivot-(y-pivot),pivot+(x-pivot)]);
  if(current.shape===undefined){const minX=Math.min(...cells.map(c=>c[0])),minY=Math.min(...cells.map(c=>c[1]));for(const c of cells){c[0]-=minX;c[1]-=minY;}}
  const nextOrientation=(orientation+(reverse?3:1))%4;
  const table=current.shape===0?LINE_KICKS:BLOCK_KICKS;
  const kicks=reverse?table[nextOrientation].map(([x,y])=>[-x,-y]):table[orientation];
  for(const [dx,dy] of kicks){const next={...current,cells,x:current.x+dx,y:current.y+dy,rotation:nextOrientation};if(fits(s,next)){s.piece=next;adjusted=true;break;}}
 }
 if(keys.includes('drop')){for(let i=0;i<21;i++)if(!lower(s))break;return;}
 if(s.version>=6){
  // Integer fixed-point gravity: preserve the early curve, then progress from
  // 1 cell/5 ticks through 1G to 20G. 20 cells already span the entire board.
  const level=Math.floor(s.lines/5),rate=level<=30?Math.floor(100000/Math.max(5,35-level)):Math.min(2000000,20000*2**Math.min(7,Math.floor((level-30)/5)));
  s.gravityUnits=(s.gravityUnits||0)+rate;
  let cells=Math.floor(s.gravityUnits/100000);s.gravityUnits%=100000;
  if(keys.includes('d'))cells=Math.max(1,cells);
  for(let i=0;i<cells;i++){const next={...s.piece,y:s.piece.y+1};if(!fits(s,next))break;s.piece=next;s.lock=0;}
 }else{
  s.fall=(s.fall||0)+1;
  if(keys.includes('d')||s.fall>=Math.max(5,35-Math.floor(s.lines/5))){
   s.fall=0;const next={...s.piece,y:s.piece.y+1};if(fits(s,next)){s.piece=next;s.lock=0;}
  }
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
 if(s.target!==undefined)s.paddle=s.version>=5?s.target:s.paddle+Math.max(-65,Math.min(65,s.target-s.paddle));
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
   if(nx<0||nx>=20||ny<0||ny>=20||s.walls.includes(n)||s.snake.slice(0,eat?undefined:-1).includes(n)){s.over=true;if(s.version>=5)s.collision={x:Math.max(0,Math.min(19,nx)),y:Math.max(0,Math.min(19,ny))};}else{s.snake.unshift(n);if(eat){s.score+=100;food(s);}else{s.snake.pop();}}
  }
 }
 if(s.game==='bird'){
  if(has('tap')||has('u')){s.vy=-65;}s.vy+=3;s.y+=s.vy;
  if(s.tick>=s.next){s.pipes.push({x:4200,gap:1300+take(s,2700),passed:false,...(s.version>=2?{half:Math.max(600,(s.version>=5?820:750)-Math.floor(s.score/15)*15)}:{})});s.next=s.tick+120;}
  for(const p of s.pipes){p.x-=s.version===1?25:Math.min(40,25+Math.floor(s.score/20));if(!p.passed&&p.x+400<900){p.passed=true;s.score++;}if(s.version>=3?birdHitsPipe(s.y,p):(p.x<1050&&p.x+400>750&&(s.y-120<p.gap-(p.half||750)||s.y+120>p.gap+(p.half||750)))){s.over=true;}}
  s.pipes=s.pipes.filter(p=>p.x>-500);if(s.version>=4&&s.y<85){s.y=85;s.vy=Math.max(0,s.vy);}if(s.y<(s.version>=3?85:120)||s.y>(s.version>=3?5515:5480)){s.over=true;}
 }
 if(s.game==='hex'){
  if(left){s.rotation=(s.rotation+5)%6;}if(right){s.rotation=(s.rotation+1)%6;}
  if(!s.falling){s.falling={lane:take(s,6),color:take(s,4)+1,distance:1900};}
  s.falling.distance-=(s.version>=5&&has('drop')?100:12)+Math.min(s.version===1?20:28,Math.floor(s.score/300));
  const lane=(s.falling.lane-s.rotation+6)%6,stack=s.lanes[lane];
  if(s.falling.distance<=stack.length*160){stack.push(s.falling.color);s.falling=null;const n=stack.length;if(s.version>=4){clearHexV4(s);}else if(n>=3&&stack[n-1]===stack[n-2]&&stack[n-2]===stack[n-3]){stack.splice(n-3,3);s.score+=100;}if((s.version>=4?s.lanes[lane]:stack).length>=10){s.over=true;}}
 }
 if(s.game==='bricks'&&s.version>=4){stepBricksV4(s,keys);}
 if(s.game==='bricks'&&s.version<4){
  if(s.version>=2){const aim=keys.find(k=>k.startsWith('x:'));if(aim){s.target=Math.max(450,Math.min(3550,Number(aim.slice(2))));}if(left||right){delete s.target;}if(s.target!==undefined){s.paddle=s.version>=5?s.target:s.paddle+Math.max(-65,Math.min(65,s.target-s.paddle));}}
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
 for(const e of events){if(!Array.isArray(e)||e.length!==2||!Number.isInteger(e[0])||e[0]<0||e[0]>=frames||e[0]<previous||typeof e[1]!=='string'||!(/^(l|r|u|d|drop|tap|x:[0-9]{1,4}|[vn]:[0-9]{1,2}:[0-9]|undo|reset)$/).test(e[1])){throw new Error('invalid_actions');}previous=e[0];(grouped[e[0]]||= []).push(e[1]);if(grouped[e[0]].length>2){throw new Error('invalid_actions');}}
 if(s.game==='2048'&&(frames>(state.version>=5?64:16)||Object.values(grouped).some(keys=>keys.length>1||!['l','r','u','d'].includes(keys[0])))){throw new Error('invalid_actions');}
 for(let i=0;i<frames;i++){if(s.over){throw new Error('already_over');}step(s,grouped[i]||[]);}return s;
}
function preview(state,dir){const s=clone(state);slide(s,dir,false);s.tick++;return s;}
const ArcadeCore={shapes:SHAPES,sudokuPuzzle,sudokuLoad,sudokuValid,sudokuSolutions,sudokuGrade,preview,version:ARCADE_VERSION,games:GAME_IDS,limits:LIMITS,radii:RADIUS,create,step,advance};
export default ArcadeCore;
