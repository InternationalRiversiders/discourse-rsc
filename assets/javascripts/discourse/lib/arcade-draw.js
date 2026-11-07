import Core from "./arcade-core";
const PALETTE=['#84ddc0','#f6bf70','#9b9ef1','#f389a2','#6dc9e8','#e9d578','#ba9dea'];
export default function draw(canvas,s,fx=null,now=performance.now()) {
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
