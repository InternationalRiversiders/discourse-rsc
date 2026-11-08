import { arcadeRequest } from './arcade-transport';
export const BRIDGE_PROTOCOL=1;
export const BRIDGE_CHANNEL='riverside.arcade';
// No cookies, credentials, arbitrary URLs or request headers cross this bridge.
export default class ArcadeBridge {
 constructor({send,onInit,onCommand,onError=()=>{},timeout=15000}){
  this.session=crypto.randomUUID();this.send=send;this.onInit=onInit;this.onCommand=onCommand;this.onError=onError;this.timeout=timeout;
  this.pending=new Map();this.commands=new Map();this.initialized=false;this.closed=false;this.commandTail=Promise.resolve();
 }
 emit(message){if(!this.closed){this.send({channel:BRIDGE_CHANNEL,protocol:BRIDGE_PROTOCOL,session:this.session,...message});}}
 ready(){this.emit({type:'ready',rules_version:2,actions:['catalog','ranking','start','advance'],commands:['pause','resume','exit','theme']});}
 receive(raw){
  let message;try{if(typeof raw==='string'&&raw.length>1048576){return;}message=typeof raw==='string'?JSON.parse(raw):raw;}catch{return;}
  if(this.closed||!message||message.channel!==BRIDGE_CHANNEL||message.protocol!==BRIDGE_PROTOCOL||message.session!==this.session){return;}
  if(message.type==='init'){
   if(this.initialized){return;}this.initialized=true;
   this.emit({type:'initialized',rules_version:2});
   Promise.resolve(this.onInit(message.payload||{})).catch(e=>this.onError(e));return;
  }
  if(!this.initialized){return;}
  if(message.type==='response'){
   const p=this.pending.get(message.id);if(!p){return;}this.pending.delete(message.id);clearTimeout(p.timer);
   if(message.error){const e=new Error(typeof message.error.message==='string'?message.error.message:'游戏请求失败，请重试。');e.code=message.error.code;e.status=message.error.status;p.reject(e);}else{p.resolve(message.result);}return;
  }
  if(message.type==='command'&&typeof message.id==='string'&&message.id.length<=100&&['pause','resume','exit','theme'].includes(message.action)){
   const key=message.id,signature=JSON.stringify([message.action,message.payload||{}]);
   const prior=this.commands.get(key);
   if(prior){if(prior.signature===signature){prior.result.then(result=>this.emit({type:'command-result',id:key,...result}));}return;}
   if(this.commands.size>=64){this.commands.delete(this.commands.keys().next().value);}
   const result=this.commandTail.then(()=>this.onCommand(message.action,message.payload||{})).then(result=>({result})).catch(e=>({error:{message:e.message||'操作失败，请重试。'}}));
   this.commandTail=result;this.commands.set(key,{signature,result});result.then(value=>this.emit({type:'command-result',id:key,...value}));
  }
 }
 request(action,payload={}){
  if(!this.initialized||this.closed){return Promise.reject(new Error('游戏连接尚未就绪'));}
  arcadeRequest(action,payload); // Validate before sending to the host; host MUST validate independently.
  if(this.pending.size>=8){return Promise.reject(new Error('请求仍在处理中，请稍后重试'));}
  const id=crypto.randomUUID();
  return new Promise((resolve,reject)=>{
   const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('网络连接超时，请重试原请求或读取已保存进度。'));},this.timeout);
   this.pending.set(id,{resolve,reject,timer});
   try{this.emit({type:'request',id,action,payload});}catch(e){clearTimeout(timer);this.pending.delete(id);reject(e);}
  });
 }
 close(){this.closed=true;for(const p of this.pending.values()){clearTimeout(p.timer);p.reject(new Error('游戏页面已关闭'));}this.pending.clear();}
}
