import assert from 'node:assert/strict';
import fs from 'node:fs';
const { atomic, decimal, estimate, payout, quantityForFraction, quantityForNotional, notionalForQuantity, openingQuantity } = await import(`data:text/javascript;base64,${Buffer.from(fs.readFileSync(new URL('../assets/javascripts/discourse/lib/rsc-estimate.js', import.meta.url))).toString('base64')}`);
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

for (const execution_mode of ['immediate','crypto_confirmation','delayed_confirmation']) {
  for (const step of ['1','0.01','0.000000000000000001']) {
    for (const quarters of [1,2,3,4]) {
      const item={quote:{price:'12.34567890123456789'},minimum:step,step,fee_bps:5,execution_mode};
      const balance='12345.678901234567890123';
      const quantity=quantityForFraction(item,'5',balance,quarters);
      const budget=atomic(balance)*BigInt(quarters)/4n;
      assert.equal(atomic(quantity)%atomic(step),0n);
      assert.ok(atomic(estimate(item,quantity,'5',balance).reserve)<=budget);
      assert.ok(atomic(estimate(item,decimal(atomic(quantity)+atomic(step)),'5',balance).reserve)>budget);
    }
  }
}
assert.equal(quantityForFraction(null,'1','100',1),null);
assert.equal(quantityForFraction({quote:{price:'100'},step:'1'},'1','0',4),'0');
console.log('PASS four allocation fractions respect fees, reservation buffers and quantity steps');

const fx={category:'forex',quote:{price:'0.006289308176100628'},minimum:'0.01',step:'0.01'};
for (const amount of ['1','10','100.123456789012345678']) {
  const quantity=quantityForNotional(fx,amount);
  assert.equal(atomic(quantity)%atomic(fx.step),0n);
  assert.ok(atomic(notionalForQuantity(fx,quantity))<=atomic(amount));
  assert.ok(atomic(notionalForQuantity(fx,decimal(atomic(quantity)+atomic(fx.step))))>atomic(amount));
}
assert.equal(quantityForNotional(fx,'0.000000000000000001'),'0');
assert.equal(quantityForNotional(fx,''),null);
assert.equal(quantityForNotional(fx,'1e3'),null);
assert.equal(notionalForQuantity(fx,''),null);
for (const category of ['forex','us','cn']) {
  const item={...fx,category};
  const units=openingQuantity(item);
  assert.ok(atomic(notionalForQuantity(item,units))>=atomic('1'));
  assert.ok(atomic(notionalForQuantity(item,decimal(atomic(units)-atomic(item.step))))<atomic('1'));
}
assert.equal(openingQuantity({...fx,category:'crypto'}),'0.01');
console.log('PASS exact FX notional conversion, step rounding, invalid drafts and minimum opening sizes');
