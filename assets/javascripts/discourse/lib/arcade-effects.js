// Presentation only. These snapshots never enter gameplay or score verification.
export function tileTracks(board, direction) {
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
export default class ArcadeEffects {
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
  overlay(ctx,now,scoreColor='#e5f6c6'){
    if(this.reducedMotion)return;
    for(const b of this.bursts){const t=(now-b.start)/500;if(t<0||t>1)continue;ctx.save();ctx.globalAlpha=1-t;ctx.strokeStyle=b.color;ctx.lineWidth=2;ctx.beginPath();ctx.arc(b.x,b.y,b.radius*(.5+t),0,Math.PI*2);ctx.stroke();
      ctx.fillStyle=b.color;for(let i=0;i<8;i++){const a=i*Math.PI/4,d=b.radius*t*2.3;ctx.fillRect(b.x+Math.cos(a)*d-1.5,b.y+Math.sin(a)*d-1.5,3,3);}ctx.restore();}
    const gain=this.scoreGain;if(gain){const t=(now-gain.start)/650;if(t>=0&&t<1){ctx.save();ctx.globalAlpha=1-t;ctx.fillStyle=scoreColor;ctx.font='700 22px system-ui';ctx.textAlign='center';ctx.fillText(`+${gain.amount}`,200,36-t*18);ctx.restore();}}
  }
}
