import fs from 'node:fs';
import Core from '../../assets/javascripts/discourse/lib/arcade-core.js';
const version=process.argv.includes("--v2")?2:1;
const rows=Core.games.map(game=>{
 const random=Array.from({length:40},(_,i)=>i*3571+733);
 const initial=Core.create(game,random,version),state=structuredClone(initial),events=[];let frames=0;
 const limit=game==='2048'?1:120;
 for(;frames<limit&&!state.over&&state.q.length>=4;frames++){
  const keys=game==='2048'?['l']:game==='merge'&&frames%45===0?['drop']:game==='bird'&&frames%20===0?['tap']:game==='blocks'&&frames%35===0?['drop']:[];
  keys.forEach(k=>events.push([frames,k]));Core.step(state,keys);
 }
 return {game,initial,frames,events,expected:state};
});
if(version===2){
 const initial=Core.create('merge',Array.from({length:20},(_,i)=>713+i*7919));
 initial.balls=Array.from({length:100},(_,i)=>({id:i,level:i%3,x:150+(i%10)*370,y:800+Math.floor(i/10)*440,vx:i%2?30:-30,vy:0}));initial.serial=100;
 const state=structuredClone(initial);let frames=0;for(;frames<180&&!state.over;frames++)Core.step(state);
 rows.push({game:'merge-stress',initial,frames,events:[],expected:state});
}
fs.writeFileSync(new URL(version===2?'./fixtures-v2.json':'./fixtures.json',import.meta.url),JSON.stringify(rows));
