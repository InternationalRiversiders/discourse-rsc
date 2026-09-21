import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { formatPrice } from "../lib/rsc-format";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
const uiText = (key) => i18n(`discourse_rsc.ui.${key}`);
const ranges = ["1d", "5d", "1mo", "6mo", "1y", "5y"];
const rangeLabel = (value) => ({ "1d": "一天", "5d": "五天", "1mo": "一月", "6mo": "半年", "1y": "一年", "5y": "五年" })[value];
export default class extends Component {
  @tracked range = "1d";
  @tracked data;
  @tracked error = "";
  @tracked loading = false;
  @tracked mode = "line";
  @tracked zoom = 1;
  @tracked offset = 0;
  @tracked hover = null;
  timer;
  drag;
  generation = 0;
  constructor() {
    super(...arguments);
    this.load("1d");
    this.timer = setInterval(() => { if (!document.hidden && !this.loading) { this.load(this.range, true); } }, 15000);
  }
  willDestroy() { super.willDestroy(...arguments); clearInterval(this.timer); this.generation++; }
  @action async load(range, preserve = false) {
    this.range = range;
    if (preserve !== true) { this.zoom = 1; this.offset = 0; this.hover = null; }
    this.loading = true;
    this.error = "";
    const generation = ++this.generation;
    try {
      const data = await ajax(
        `/rsc/instruments/${this.args.instrument.id}/history.json`,
        { data: { range } }
      );
      if (!this.isDestroying && generation === this.generation) {
        this.data = data;
      }
    } catch (error) {
      if (!this.isDestroying && generation === this.generation) {
        this.error = extractError(error);
        this.data = undefined;
      }
    } finally {
      if (!this.isDestroying && generation === this.generation) {
        this.loading = false;
      }
    }
  }
  @action toggle() {
    this.mode = this.mode === "line" ? "candles" : "line";
  }
  @action zoomIn() {
    this.zoom = Math.min(16, this.zoom * 2);
  }
  @action reset() {
    this.zoom = 1;
    this.offset = 0;
  }
  @action zoomOut() {
    this.zoom = Math.max(1, this.zoom / 2);
    this.offset = Math.min(this.offset, 1 - 1 / this.zoom);
  }
  @action pan(direction) {
    this.offset = Math.max(
      0,
      Math.min(1 - 1 / this.zoom, this.offset + direction / this.zoom / 2)
    );
  }
  @action pointerDown(event) {
    if (event.button !== 0) {
      return;
    }
    this.drag = {
      x: event.clientX,
      offset: this.offset,
      width: event.currentTarget.getBoundingClientRect().width,
    };
    event.currentTarget.setPointerCapture(event.pointerId);
  }
  @action pointerMove(event) {
    const bounds = event.currentTarget.getBoundingClientRect();
    const chart = this.chart;
    if (chart) { const index = Math.max(0, Math.min(chart.candles.length - 1, Math.round(((event.clientX - bounds.left) / bounds.width * 600 - 20) / 560 * (chart.candles.length - 1)))); this.hover = chart.candles[index]; }
    if (this.drag) {
      this.offset = Math.max(
        0,
        Math.min(
          1 - 1 / this.zoom,
          this.drag.offset +
            (event.clientX - this.drag.x) / this.drag.width / this.zoom
        )
      );
    }
  }
  @action pointerLeave() { if (!this.drag) { this.hover = null; } }
  @action pointerUp() {
    this.drag = null;
  }
  get chart() {
    if (this.error) {
      return null;
    }
    let allRows =
      this.data?.candles ||
      this.args.instrument.history?.map((p) => ({
        at: p.at,
        close: p.price,
      })) ||
      [];
    // Reflect new observations between cached provider chart refreshes. Historical
    // snapshots never become live points, and local-currency prices are explicit.
    if (["1d", "5d"].includes(this.range) && !this.data?.archived && !this.args.instrument.quote?.legacy_snapshot) {
      const quote = this.args.instrument.quote;
      const close = this.data?.currency === "RSC" || this.data?.currency === "USD" ? quote?.price : quote?.local_price;
      if (close && quote?.source_time && (!allRows.length || Date.parse(quote.source_time) >= Date.parse(allRows.at(-1).at))) {
        allRows = [...allRows.filter((p) => p.at !== quote.source_time), { at: quote.source_time, close }];
      }
    }
    const size = Math.max(2, Math.ceil(allRows.length / this.zoom));
    const end = Math.max(
      size,
      allRows.length - Math.round(this.offset * allRows.length)
    );
    const rows = allRows.slice(Math.max(0, end - size), end);
    const values = rows.map((p) => Number(p.close)).filter(Number.isFinite);
    if (values.length < 2) {
      return null;
    }
    const max = Math.max(...rows.map((p) => Number(p.high || p.close))),
      min = Math.min(...rows.map((p) => Number(p.low || p.close)));
    const span = max - min || 1,
      y = (value) => 160 - ((Number(value) - min) / span) * 140;
    return {
      high: formatPrice(String(max)),
      low: formatPrice(String(min)),
      start: rows[0].at ? new Date(rows[0].at).toLocaleDateString() : "—",
      end: rows.at(-1).at ? new Date(rows.at(-1).at).toLocaleDateString() : "—",
      points: rows
        .map((p, i) => `${20 + (i * 560) / (rows.length - 1)},${y(p.close)}`)
        .join(" "),
      candles: rows.map((p, i) => ({
        x: 20 + (i * 560) / (rows.length - 1),
        top: y(p.high || p.close),
        bottom: y(p.low || p.close),
        y: Math.min(y(p.open || p.close), y(p.close)),
        height: Math.max(1, Math.abs(y(p.open || p.close) - y(p.close))),
        width: Math.max(1, Math.min(8, 450 / rows.length)),
        tone:
          Number(p.close) >= Number(p.open || p.close)
            ? "positive"
            : "negative",
        title: `${p.at ? new Date(p.at).toLocaleString() : ""} · 开 ${formatPrice(p.open)} 高 ${formatPrice(p.high)} 低 ${formatPrice(p.low)} 收 ${formatPrice(p.close)}`,
      })),
    };
  }
  <template>
    <div class="rsc-history" aria-busy={{this.loading}}>
      <div class="rsc-chart-controls">{{#each ranges as |range|}}<button
            type="button"
            class="btn btn-small {{if (eq this.range range) 'btn-primary'}}"
            {{on "click" (fn this.load range)}}
          >{{rangeLabel range}}</button>{{/each}}<button
          type="button"
          class="btn btn-small"
          {{on "click" this.toggle}}
        >{{uiText "chart_mode"}}</button></div>
      <div class="rsc-chart-controls"><button
          type="button"
          class="btn btn-small"
          aria-label={{uiText "zoom_in"}}
          {{on "click" this.zoomIn}}
        >+</button><button
          type="button"
          class="btn btn-small"
          aria-label={{uiText "zoom_out"}}
          {{on "click" this.zoomOut}}
        >−</button><button
          type="button"
          class="btn btn-small"
          aria-label={{uiText "pan_earlier"}}
          {{on "click" (fn this.pan 1)}}
        >←</button><button
          type="button"
          class="btn btn-small"
          aria-label={{uiText "pan_later"}}
          {{on "click" (fn this.pan -1)}}
        >→</button><button
          type="button"
          class="btn btn-small"
          {{on "click" this.reset}}
        >{{uiText "reset_chart"}}</button></div>
      {{#if this.error}}<p
          role="alert"
          class="rsc-muted"
        >{{this.error}}</p>{{/if}}
      {{#if this.data.stale}}<p class="rsc-muted" role="status">{{uiText "chart_stale"}}</p>{{/if}}
      {{#if this.data.archived}}<p class="rsc-muted">{{uiText
            "archived_chart"
          }}</p>{{/if}}
      {{#if this.chart}}<svg
          class="rsc-interactive-chart"
          {{on "pointerdown" this.pointerDown}}
          {{on "pointermove" this.pointerMove}}
          {{on "pointerleave" this.pointerLeave}}
          {{on "pointerup" this.pointerUp}}
          {{on "pointercancel" this.pointerUp}}
          viewBox="0 0 600 180"
          role="img"
          aria-label={{uiText "price_chart"}}
        >
          {{#if this.hover}}<line x1={{this.hover.x}} x2={{this.hover.x}} y1="10" y2="170" stroke="currentColor" stroke-dasharray="3 3" opacity="0.5" />{{/if}}
          {{#if (eq this.mode "line")}}<polyline
              points={{this.chart.points}}
              fill="none"
              stroke="currentColor"
              stroke-width="2"
            />
          {{else}}{{#each this.chart.candles as |candle|}}<g
                class={{candle.tone}}
              ><title>{{candle.title}}</title><line
                  x1={{candle.x}}
                  x2={{candle.x}}
                  y1={{candle.top}}
                  y2={{candle.bottom}}
                  stroke="currentColor"
                /><rect
                  x={{candle.x}}
                  y={{candle.y}}
                  width={{candle.width}}
                  height={{candle.height}}
                  fill="currentColor"
                /></g>{{/each}}{{/if}}
        </svg>{{#if this.hover}}<p class="rsc-chart-tooltip" role="status">{{this.hover.title}}</p>{{/if}}<div class="rsc-chart-axis"><span
          >{{this.chart.low}}–{{this.chart.high}}
            {{this.data.currency}}</span><span>{{this.chart.start}}
            →
            {{this.chart.end}}</span></div>{{else}}<p class="rsc-muted">{{uiText
            "empty"
          }}</p>{{/if}}
    </div>
  </template>
}
