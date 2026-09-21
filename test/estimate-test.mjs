import assert from 'node:assert/strict';
import fs from 'node:fs';
const { atomic, decimal, estimate, payout } = await import(`data:text/javascript;base64,${Buffer.from(fs.readFileSync(new URL('../assets/javascripts/discourse/lib/rsc-estimate.js', import.meta.url))).toString('base64')}`);
assert.equal(atomic('0.000000000000000001'), 1n);
assert.equal(atomic('1e5'), null);
assert.equal(decimal(atomic('10000000000000000.000000000000000001')), '10000000000000000.000000000000000001');
assert.equal(payout('0.01','1.85'),'0.0185');
for (const execution_mode of ['immediate','crypto_confirmation','delayed_confirmation']) {
  for (const step of ['1','0.1','0.000000000000000001']) {
    const item={quote:{price:'123.4567890123456789'},step,fee_bps:5,execution_mode};
    const result=estimate(item,'1',10,'100');
    assert.ok(result);
    assert.equal(atomic(result.maximum)%atomic(step),0n);
    const atMaximum=estimate(item,result.maximum,10,'100');
    assert.ok(atomic(atMaximum.reserve)<=atomic('100'));
    const next=estimate(item,decimal(atomic(result.maximum)+atomic(step)),10,'100');
    assert.ok(atomic(next.reserve)>atomic('100'));
  }
}
assert.equal(estimate({quote:{price:'100'},step:'1'},'1',1,'0').maximum,'0');
console.log('PASS exact decimal arithmetic, payout and affordable step boundaries for all execution modes');
