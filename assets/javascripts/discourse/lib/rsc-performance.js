// Realized P&L is a balance: carry it between settlements, never interpolate gains.
export function performanceChart(rows = [], days = 0, now = Date.now()) {
  const cutoff = days > 0 ? now - days * 86400000 : -Infinity;
  const all = rows.map((row) => ({ at: Date.parse(row.at), value: row.pnl == null ? NaN : Number(row.pnl) }))
    .filter((row) => Number.isFinite(row.at) && row.at <= now).sort((a, b) => a.at - b.at);
  const points = all.filter((row) => row.at >= cutoff);
  const previous = all.findLast((row) => row.at < cutoff);
  if (previous && points.length && points[0].at > cutoff) { points.unshift({ ...previous, at: cutoff }); }
  const groups = [];
  let group = [];
  for (const point of points) {
    if (Number.isFinite(point.value)) { group.push(point); }
    else { if (group.length >= 2) { groups.push(group); } group = []; }
  }
  if (group.length >= 2) { groups.push(group); }
  const visible = groups.flat();
  if (!visible.length) { return null; }
  const start = visible[0].at, end = visible.at(-1).at;
  const values = visible.map((point) => point.value);
  const min = Math.min(...values), max = Math.max(...values);
  const x = (at) => 12 + 576 * (at - start) / (end - start || 1);
  const y = (value) => max === min ? 80 : 144 - 128 * (value - min) / (max - min);
  const segments = groups.map((segment) => segment.flatMap((point, index) => {
    const current = `${x(point.at)},${y(point.value)}`;
    return index ? [`${x(point.at)},${y(segment[index - 1].value)}`, current] : [current];
  }).join(" "));
  return { segments, start, end, min, max, last: visible.at(-1).value };
}
