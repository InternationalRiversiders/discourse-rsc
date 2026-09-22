// Preserve observed cumulative returns; a range does not rebase or invent data.
export function performanceChart(rows = [], days = 0, now = Date.now()) {
  const cutoff = days > 0 ? now - days * 86400000 : -Infinity;
  const points = rows.map((row) => ({
    at: Date.parse(row.at),
    value: row.return_pct == null ? NaN : Number(row.return_pct),
  })).filter((row) => Number.isFinite(row.at) && row.at >= cutoff && row.at <= now)
    .sort((a, b) => a.at - b.at);
  const groups = [];
  let group = [];
  for (const point of points) {
    if (Number.isFinite(point.value)) {
      group.push(point);
    } else {
      if (group.length >= 2) { groups.push(group); }
      group = [];
    }
  }
  if (group.length >= 2) { groups.push(group); }
  const visible = groups.flat();
  if (!visible.length) { return null; }
  const start = visible[0].at, end = visible.at(-1).at;
  const values = visible.map((point) => point.value);
  const min = Math.min(...values), max = Math.max(...values);
  const segments = groups.map((segment) => segment.map((point) => {
    const x = 12 + 576 * (point.at - start) / (end - start || 1);
    const y = max === min ? 80 : 144 - 128 * (point.value - min) / (max - min);
    return `${x},${y}`;
  }).join(" "));
  return { segments, start, end, last: visible.at(-1).value };
}
