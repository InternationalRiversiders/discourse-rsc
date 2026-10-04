const U = 10n ** 18n;
export function atomic(value) {
  const match = /^(0|[1-9][0-9]*)(?:\.([0-9]{1,18}))?$/.exec(String(value ?? ""));
  return match ? BigInt(match[1]) * U + BigInt((match[2] || "").padEnd(18, "0")) : null;
}
export function decimal(value) {
  return `${value / U}.${(value % U).toString().padStart(18, "0")}`.replace(/\.?0+$/, "");
}
const ceil = (a, b) => (a + b - 1n) / b;
export function estimate(instrument, quantity, leverage, balance) {
  try {
    const price = atomic(instrument?.quote?.price), qty = atomic(quantity), available = atomic(balance);
    if (!price || !qty || available === null || !/^[1-9][0-9]{0,2}$/.test(String(leverage))) { return null; }
    const lev = BigInt(leverage), feeBps = BigInt(instrument.fee_bps ?? 5);
    const step = atomic(instrument.step) || U;
    const pending = instrument.execution_mode !== "immediate";
    const cost = (units) => {
      const gross = units * price / U;
      return pending ? ceil(gross * 105n, 100n * lev) + ceil(gross * 105n * feeBps, 1000000n) : ceil(gross, lev) + gross * feeBps / 10000n;
    };
    let low = 0n, high = available * lev * U / price / step + 1n;
    while (low + 1n < high) { const mid = (low + high) / 2n; if (cost(mid * step) <= available) { low = mid; } else { high = mid; } }
    const gross = qty * price / U;
    return { gross: decimal(gross), margin: decimal(ceil(gross, lev)), fee: decimal(gross * feeBps / 10000n), reserve: decimal(cost(qty)), maximum: decimal(low * step) };
  } catch { return null; }
}
export function payout(stake, odds) {
  const amount = atomic(stake), rate = atomic(odds);
  return amount !== null && rate !== null ? decimal(amount * rate / U) : null;
}

// Allocate a fraction of available cash, rounding down to the instrument step.
// Independent of the quantity draft, so shortcuts work after clearing the field.
export function quantityForFraction(instrument, leverage, balance, quarters) {
  const available = atomic(balance);
  if (available === null || ![1, 2, 3, 4].includes(quarters)) { return null; }
  const budget = decimal(available * BigInt(quarters) / 4n);
  const result = estimate(instrument, instrument?.minimum || instrument?.step || "1", leverage, budget);
  return result?.maximum ?? null;
}

// Notional is the face value of the trade, not margin. Never exceed the entered
// amount or manufacture a minimum-sized order when the amount is too small.
export function quantityForNotional(instrument, amount) {
  const price = atomic(instrument?.quote?.price), notional = atomic(amount);
  const step = atomic(instrument?.step);
  if (!price || notional === null || !step) { return null; }
  return decimal((notional * U / price / step) * step);
}

export function notionalForQuantity(instrument, quantity) {
  const price = atomic(instrument?.quote?.price), units = atomic(quantity);
  return price && units !== null ? decimal(price * units / U) : null;
}

// Stock-like products require at least 1 RSC notional; FX uses the same useful
// initial size instead of defaulting to a near-zero 0.01 currency-unit order.
export function openingQuantity(instrument) {
  const price = atomic(instrument?.quote?.price), step = atomic(instrument?.step);
  const minimum = atomic(instrument?.minimum);
  if (!price || !step || !minimum || !(instrument?.minimum_notional || ["forex", "stock", "us", "cn", "hk", "jp", "eu", "ca", "au", "sg", "in"].includes(instrument?.category))) {
    return instrument?.minimum || "1";
  }
  const target = atomic(instrument.minimum_notional || "1") || U;
  const sized = ceil(target * U, price * step) * step;
  const floor = ceil(minimum, step) * step;
  return decimal(sized > floor ? sized : floor);
}
