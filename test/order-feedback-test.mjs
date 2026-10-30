import assert from 'node:assert/strict';
import fs from 'node:fs';
import { webcrypto } from 'node:crypto';
const source=fs.readFileSync(new URL('../assets/javascripts/discourse/components/rsc-dashboard.gjs',import.meta.url),'utf8');
// Exercise the real component's asynchronous methods with controllable requests.
const methods=source.slice(source.indexOf('  async loadState('),source.indexOf('  @action transfer('));
function fixture(){
  const requests=[];
  const ajax=(url,options)=>new Promise((resolve,reject)=>requests.push({url,options,resolve,reject}));
  const Component=new Function('ajax','crypto','uiText','extractError',`return class { ${methods} }`)(ajax,webcrypto,x=>x,e=>e.message);
  const c=new Component();
  Object.assign(c,{data:{read_only:false,market_data_enabled:true},args:{section:'market',model:{}},marketDetailOpen:true,selected:{id:1},selectedId:1,marketQuery:{},stateGeneration:0,busy:false,requestIds:new Map(),snapshot:{balance:'old'}});
  return {c,requests};
}
const flush=async()=>{await Promise.resolve();await Promise.resolve();};
{
  const {c,requests}=fixture();
  const oldRead=c.loadState(false);
  const send=c.send('orders',{quantity:'1'});
  requests[1].resolve({status:'filled',order_id:1});
  assert.equal((await send).status,'filled');
  assert.equal(c.busy,false);
  assert.equal(c.notice,'已成交。');
  assert.equal(requests.length,3);
  assert.equal(requests[2].url,'/rsc/state.json');
  assert.ok(!requests.some(r=>r.url.includes('/refresh.json')));
  requests[0].resolve({balance:'before-order'});await oldRead;
  assert.deepEqual(c.snapshot,{balance:'old'});
  requests[2].resolve({balance:'after-order'});await flush();
  assert.deepEqual(c.snapshot,{balance:'after-order'});
}
{
  const {c,requests}=fixture();
  const send=c.send('orders',{quantity:'1'});
  requests[0].resolve({status:'filled'});await send;
  requests[1].reject(new Error('state unavailable'));await flush();
  assert.equal(c.error,'');assert.equal(c.busy,false);
  assert.match(c.notice,/已成交.*无需重复提交/s);
  assert.equal(c.requestIds.size,0);
}
{
  const {c,requests}=fixture();
  const send=c.send('orders',{quantity:'1'});
  const requestId=requests[0].options.data.request_id;
  requests[0].reject(new Error('network unknown'));await send;
  assert.equal(c.error,'network unknown');assert.equal(c.busy,false);
  assert.equal(requests.length,1);
  const retry=c.send('orders',{quantity:'1'});
  assert.equal(requests[1].options.data.request_id,requestId);
  requests[1].resolve({status:'filled'});await retry;
  requests[2].resolve({balance:'updated'});await flush();
}
{
  const {c,requests}=fixture();
  const first=c.send('orders',{quantity:'1'});requests[0].resolve({status:'filled'});await first;
  const second=c.send('orders',{quantity:'2'});requests[2].resolve({status:'filled'});await second;
  requests[1].reject(new Error('old refresh failed'));await flush();
  assert.equal(c.notice,'已成交。');
  requests[3].resolve({balance:'second-order'});await flush();
  assert.deepEqual(c.snapshot,{balance:'second-order'});
}
console.log('PASS immediate success feedback, background refresh, stale-read suppression and safe idempotent retry');
