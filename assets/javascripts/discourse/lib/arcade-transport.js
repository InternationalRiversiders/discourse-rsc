const games=['2048','blocks','snake','bird','hex','bricks','merge','sudoku'];
const fail=()=>{throw new Error('无效的游戏请求');};
// Also supplied to native implementers as the exact API allowlist contract.
export function arcadeRequest(action,payload={}){
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
