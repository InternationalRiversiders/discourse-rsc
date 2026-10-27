import assert from 'node:assert/strict';
import fs from 'node:fs';
const source=fs.readFileSync(new URL('../assets/javascripts/discourse/lib/rsc-market.js',import.meta.url),'utf8');
const format=fs.readFileSync(new URL('../assets/javascripts/discourse/lib/rsc-format.js',import.meta.url),'utf8');
const formatUrl=`data:text/javascript;base64,${Buffer.from(format).toString('base64')}`;
const {marketView,canRefreshForTrade}=await import(`data:text/javascript;base64,${Buffer.from(source.replace('"./rsc-format"',JSON.stringify(formatUrl))).toString('base64')}`);
const now=Date.now(),at=n=>new Date(now+n).toISOString();
const item={category:'forex',market_closed:false,quote:{price:'0.15',source_time:at(-600000),received_at:at(-1000),session_start:at(-3600000),session_end:at(3600000)}};
assert.equal(marketView(item,now).tradable,false);
assert.equal(canRefreshForTrade(marketView(item,now)),true);
for(const changed of [{market_closed:true},{active:false},{category:'us'},{category:'crypto'},{quote:{}},{quote:{...item.quote,source_time:at(-1000)}}]){
 assert.equal(canRefreshForTrade(marketView({...item,...changed},now)),false);
}
assert.equal(canRefreshForTrade(undefined),false);
console.log('Stale FX can request refresh; closed/inactive/no-price/non-FX remain blocked.');
