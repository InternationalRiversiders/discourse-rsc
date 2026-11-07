import Core from "./arcade-core";
const PALETTE=['#84ddc0','#f6bf70','#9b9ef1','#f389a2','#6dc9e8','#e9d578','#ba9dea'];
export default function draw(canvas,s) {
 const ctx=canvas.getContext('2d');if(!ctx){return;}const width=400,height=s.game==='2048'||s.game==='snake'?400:560;
 const scale=Math.min(window.devicePixelRatio||1,2);if(canvas.width!==width*scale||canvas.height!==height*scale){canvas.width=width*scale;canvas.height=height*scale;canvas.style.aspectRatio=`${width}/${height}`;}
 ctx.setTransform(scale,0,0,scale,0,0);ctx.fillStyle='#102c39';ctx.fillRect(0,0,width,height);
 const box=(x,y,w,h,color,r=6)=>{ctx.fillStyle=color;ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fill();};
 const text=(v,x,y,size=24,color='#effaf8')=>{ctx.fillStyle=color;ctx.font=`700 ${size}px system-ui`;ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillText(String(v),x,y);};
 if(s.game==='2048'){
  s.board.forEach((v,i)=>{const x=12+i%4*97,y=12+Math.floor(i/4)*97;box(x,y,85,85,v?PALETTE[(Math.log2(v)-1)%7]:'#203e4c',12);if(v){text(v,x+42,y+43,v>=10000?21:29,'#13323b');}});
 }
 if(s.game==='blocks'){
  const cell=(i,v)=>{if(v){box(60+i%10*28,Math.floor(i/10)*28,26,26,PALETTE[(v-1)%7],4);}};
  ctx.strokeStyle='#23424f';for(let x=60;x<=340;x+=28){ctx.beginPath();ctx.moveTo(x,0);ctx.lineTo(x,560);ctx.stroke();}
  s.board.forEach((v,i)=>cell(i,v));if(s.piece){s.piece.cells.forEach(([x,y])=>cell((y+s.piece.y)*10+x+s.piece.x,s.piece.color));}
 }
 if(s.game==='snake'){
  s.walls.forEach(i=>box(i%20*20+1,Math.floor(i/20)*20+1,18,18,'#526775',3));
  s.snake.forEach((i,k)=>box(i%20*20+1,Math.floor(i/20)*20+1,18,18,k?'#6ed3ac':'#d5f89b',5));
  box(s.food%20*20+3,Math.floor(s.food/20)*20+3,14,14,'#ff9e9f',7);
 }
 if(s.game==='bird'){
  ctx.fillStyle='#1d4351';for(let i=0;i<8;i++){ctx.beginPath();ctx.arc((i*71-s.tick/3)%470,80+i%3*130,24,0,7);ctx.fill();}
  s.pipes.forEach(p=>{box(p.x/10,0,40,(p.gap-750)/10,'#70c9ad',4);box(p.x/10,(p.gap+750)/10,40,560-(p.gap+750)/10,'#70c9ad',4);});
  ctx.save();ctx.translate(90,s.y/10);ctx.rotate(Math.max(-.4,Math.min(.7,s.vy/120)));box(-15,-12,30,24,'#f8d17f',10);ctx.fillStyle='#173849';ctx.beginPath();ctx.arc(8,-4,3,0,7);ctx.fill();box(-14,0,14,8,'#f3a872',5);ctx.restore();
 }
 if(s.game==='hex'){
  const cx=200,cy=280,hex=(radius)=>{ctx.beginPath();for(let i=0;i<6;i++){const a=i*Math.PI/3;ctx.lineTo(cx+Math.cos(a)*radius,cy+Math.sin(a)*radius);}ctx.closePath();};
  hex(43);ctx.fillStyle='#94d7c1';ctx.fill();text('⬡',cx,cy,35,'#173849');
  const block=(lane,dist,color)=>{const a=lane*Math.PI/3;ctx.save();ctx.translate(cx+Math.cos(a)*dist,cy+Math.sin(a)*dist);ctx.rotate(a);box(-7,-19,14,38,PALETTE[color-1],3);ctx.restore();};
  s.lanes.forEach((lane,i)=>lane.forEach((c,j)=>block((i+s.rotation)%6,52+j*16,c)));
  if(s.falling){block(s.falling.lane,52+s.falling.distance/10,s.falling.color);}
 }
 if(s.game==='bricks'){
  s.board.forEach((v,i)=>{if(v){box(10+i%8*47.5,60+Math.floor(i/8)*22,43.5,18,PALETTE[Math.floor(i/8)],4);}});
  box(s.paddle/10-45,508,90,10,'#b3ead8',5);ctx.beginPath();ctx.arc(s.x/10,s.y/10,6,0,7);ctx.fillStyle='#fff0ba';ctx.fill();text('●'.repeat(s.lives),200,540,15,'#91c9be');
 }
 if(s.game==='merge'){
  ctx.strokeStyle=s.danger?'#ff8497':'#496774';ctx.setLineDash([5,6]);ctx.beginPath();ctx.moveTo(8,40);ctx.lineTo(392,40);ctx.stroke();ctx.setLineDash([]);
  const fruits=['🍒','🍓','🍇','🍊','🍎','🍐','🍑','🍍','🥥','🍈','🍉'];
  const fruit=(x,y,level,ghost=false)=>{const r=Core.radii[level]/10;ctx.globalAlpha=ghost?.55:1;ctx.beginPath();ctx.arc(x,y,r,0,7);ctx.fillStyle=PALETTE[level%7];ctx.fill();text(fruits[level],x,y,r*1.3);ctx.globalAlpha=1;};
  s.balls.forEach(b=>fruit(b.x/10,b.y/10,b.level));if(s.drops<100){fruit(s.aim/10,25,s.next,true);}
 }
}
