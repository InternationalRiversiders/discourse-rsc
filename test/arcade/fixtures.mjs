import fs from 'node:fs';
import Core from '../../assets/javascripts/discourse/lib/arcade-core.js';
const rows=Core.games.map(game=>{
 const random=Array.from({length:40},(_,i)=>i*3571+733);
 const initial=Core.create(game,random),state=structuredClone(initial),events=[];let frames=0;
 const limit=game==='2048'?1:120;
 for(;frames<limit&&!state.over&&state.q.length>=4;frames++){
  const keys=game==='2048'?['l']:game==='merge'&&frames%45===0?['drop']:game==='bird'&&frames%20===0?['tap']:game==='blocks'&&frames%35===0?['drop']:[];
  keys.forEach(k=>events.push([frames,k]));Core.step(state,keys);
 }
 return {game,initial,frames,events,expected:state};
});
fs.writeFileSync(new URL('./fixtures.json',import.meta.url),JSON.stringify(rows));
