import Core from "./arcade-core";
import draw from "./arcade-draw";
import { loadMergeSprites } from "./arcade-sprites";
export default function drawCover(canvas,game){
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
