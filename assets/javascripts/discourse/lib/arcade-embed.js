import Core from "./arcade-core";
import ArcadeApp, { GAMES } from './arcade-app';
import ArcadeBridge from './arcade-bridge';

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
 app=new ArcadeApp(root,{game,hostNavigation:!!game&&payload.host_navigation===true,request:(action,data)=>{if(retired){throw new Error('游戏已退出，请重新打开');}return bridge.request(action,data);},reloadCatalog:()=>loadCatalog(),
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
