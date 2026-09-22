import { formatPrice } from "./rsc-format";
// Presentation only. Order amounts and authoritative execution stay on the server.
export function marketView(item, now = Date.now()) {
  const quote = item.quote || {};
  const received = Date.parse(quote.received_at);
  const source = Date.parse(quote.source_time);
  const delay = Math.max(0, Number(quote.delay_seconds) || 0);
  const fresh =
    !quote.legacy_snapshot &&
    Number.isFinite(received) &&
    Number.isFinite(source) &&
    received >= now - 120000 &&
    received <= now + 5000 &&
    source <= now + 5000 &&
    source >= now - (delay + 120) * 1000;
  const open =
    item.category === "crypto" ||
    (!item.market_closed && now >= Date.parse(quote.session_start) &&
      now < Date.parse(quote.session_end));
  const available = typeof quote.price === "string" && Number(quote.price) > 0;
  const status = !available
    ? "no_quote"
    : !fresh
      ? "stale_quote"
      : !open
        ? "session_closed"
        : delay > 120
          ? "delayed_quote"
          : "session_open";
  // Daily change needs a previous-close value, never the first chart sample.
  const previous = Number(quote.previous_close);
  const change =
    available && Number.isFinite(previous) && previous > 0
      ? (Number(quote.price) / previous - 1) * 100
      : null;
  return {
    ...item,
    display_symbol: item.display_symbol || item.symbol,
    status,
    tradable: available && fresh && open,
    change,
    changeLabel: item.category === "crypto" ? (quote.change_basis === "utc_open" || quote.source === "kraken" ? "今日涨跌（UTC）" : (quote.change_basis === "24h" || ["coinbase", "coinbase_ws", "okx"].includes(quote.source) ? "24h 涨跌" : "参考涨跌")) : "较前收",
    changeText:
      change === null ? "—" : `${change > 0 ? "+" : ""}${change.toFixed(2)}%`,
    tone:
      change === null || change === 0
        ? "neutral"
        : change > 0
          ? "positive"
          : "negative",
    localPrice:
      quote.local_price && quote.local_currency
        ? `${formatPrice(quote.local_price)} ${quote.local_currency}`
        : "—",
  };
}

export function sparkline(history) {
  const values = (history || [])
    .map((item) => Number(item.price))
    .filter(Number.isFinite);
  if (values.length < 2) {
    return "";
  }
  const min = Math.min(...values),
    span = Math.max(...values) - min || 1;
  return values
    .map(
      (value, index) =>
        `${(index * 600) / (values.length - 1)},${130 - ((value - min) * 110) / span}`
    )
    .join(" ");
}
