import Core from "./arcade-core";
const BLOCK_COLORS=['#6dc9e8','#e9d578','#ba9dea','#84ddc0','#f389a2','#7f9ae0','#f6bf70'];
const PALETTE=['#84ddc0','#f6bf70','#9b9ef1','#f389a2','#6dc9e8','#e9d578','#ba9dea'];
export default function draw(canvas,s,fx=null,now=performance.now()) {
 const ctx=canvas.getContext('2d');if(!ctx){return;}const width=s.game==='blocks'?296:400,height=s.game==='blocks'?576:s.game==='2048'||s.game==='snake'||s.game==='hex'?400:560;
 const scale=Math.min(window.devicePixelRatio||1,2);if(canvas.width!==width*scale||canvas.height!==height*scale){canvas.width=width*scale;canvas.height=height*scale;canvas.style.aspectRatio=`${width}/${height}`;}
 ctx.setTransform(scale,0,0,scale,0,0);ctx.fillStyle='#102c39';ctx.fillRect(0,0,width,height);
 const box=(x,y,w,h,color,r=6)=>{ctx.fillStyle=color;ctx.beginPath();ctx.roundRect(x,y,w,h,r);ctx.fill();};
 const text=(v,x,y,size=24,color='#effaf8')=>{ctx.fillStyle=color;ctx.font=`700 ${size}px system-ui`;ctx.textAlign='center';ctx.textBaseline='middle';ctx.fillText(String(v),x,y);};
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
