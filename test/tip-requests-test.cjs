const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const source = fs.readFileSync(require('node:path').join(__dirname, '../assets/javascripts/discourse/lib/rsc-tip-requests.js'), 'utf8');
const TipRequests = vm.runInNewContext(source.replace('export default class TipRequests', 'class TipRequests') + '\nTipRequests', { Date, Promise, Map, Error, Number, Object, setTimeout, clearTimeout });
function harness(request) {
  let now = 100000, sequence = 0;
  const timers = new Map(), calls = [];
  const queue = new TipRequests({now: () => now, setTimer: (fn, delay) => { const id = ++sequence; timers.set(id, { fn, at: now + delay }); return id; }, clearTimer: id => timers.delete(id), request: async (topic, ids) => { calls.push({ at: now, topic, ids }); return request ? request(topic, ids) : { posts: {} }; }});
  async function advance(ms) {
    const end = now + ms;
    for (;;) {
      await new Promise(resolve => setImmediate(resolve));
      const next = [...timers].filter(([,t]) => t.at <= end).sort((a,b) => a[1].at-b[1].at)[0];
      if (!next) { now = end; break; }
      timers.delete(next[0]); now = next[1].at; next[1].fn();
    }
    await new Promise(resolve => setImmediate(resolve));
  }
  return {queue, calls, advance, timers};
}
const post = id => ({id, topic_id: 1});
test('rapid scrolling batches across frames, spaces requests, and caches empty summaries', async () => {
  const h = harness(), promises = [];
  for (let id = 1; id <= 105; id++) { promises.push(h.queue.get(post(id))); await h.advance(20); }
  await h.advance(3000); await Promise.all(promises);
  assert(h.calls.length <= 4, `105 posts used ${h.calls.length} requests`);
  for(let i=1;i<h.calls.length;i++) assert(h.calls[i].at-h.calls[i-1].at>=1000);
  const before = h.calls.length;
  await Promise.all(Array.from({length:105}, (_,i)=>h.queue.get(post(i+1))));
  await h.advance(1000); assert.equal(h.calls.length,before);
});
test('deduplicates pending and in-flight posts; explicit refresh waits for the old read', async () => {
  let complete;
  const h=harness(()=>new Promise(resolve=>complete=resolve));
  const a=h.queue.get(post(1));assert.equal(h.queue.get(post(1)),a);
  await h.advance(250);assert.equal(h.queue.get(post(1)),a);
  const refresh=h.queue.get(post(1),true);
  complete({posts:{1:{count:0}}});await a;await h.advance(1000);
  assert.equal(h.calls.length,2);complete({posts:{1:{count:1}}});assert.equal((await refresh).count,1);
});
test('respects endpoint batch size and separates topics',async()=>{
  const h=harness(),promises=[];
  for(let i=1;i<=205;i++)promises.push(h.queue.get(post(i)));
  promises.push(h.queue.get({id:206,topic_id:2}));
  await h.advance(5000);await Promise.all(promises);
  assert.equal(h.calls.length,4);assert(h.calls.every(c=>c.ids.length<=100));assert.equal(h.calls[3].topic,2);
});
for(const retry of ['10',null,'Thu, 01 Jan 1970 00:01:50 GMT']){
 test(`429 cooldown (${retry}) rejects queued work without automatic retries`,async()=>{
  const error=Object.assign(new Error('rate limited'),{status:429,getResponseHeader:()=>retry});let fail=true;
  const h=harness(()=>{if(fail)throw error;return {posts:{}};});
  const result=h.queue.get(post(1)).catch(e=>e);const other=h.queue.get({id:2,topic_id:2}).catch(e=>e);
  await h.advance(250);assert.equal(await result,error);assert.equal(await other,error);
  await assert.rejects(h.queue.get(post(3)));await h.advance(5000);assert.equal(h.calls.length,1);assert.equal(h.timers.size,0);
  await h.advance(60000);assert.equal(h.calls.length,1);
  fail=false;const recovered=h.queue.get(post(3));await h.advance(250);await recovered;assert.equal(h.calls.length,2);
 });
}
test('transient errors back off and teardown cancels queued requests',async()=>{
 const h=harness(()=>{throw new Error('network');});const result=h.queue.get(post(1)).catch(e=>e);await h.advance(250);await result;
 await assert.rejects(h.queue.get(post(2)));await h.advance(5000);
 const pending=h.queue.get(post(2)).catch(e=>e);h.queue.destroy();await pending;await h.advance(1000);assert.equal(h.calls.length,1);
});
