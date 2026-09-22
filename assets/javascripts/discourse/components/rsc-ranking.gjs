import { formatDateTime, formatDate } from "../lib/campus-time";
import RscNavigation from "./rsc-navigation";
import RscPagination from "./rsc-pagination";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import {
  formatAmount,
  formatPercent,
  formatQuantity,
  valueTone,
} from "../lib/rsc-format";
const uiText = (key) => i18n(`discourse_rsc.ui.${key}`);
const sorts = [
  "equity",
  "total_pnl",
  "return_pct",
  "portfolio_equity",
  "realized_pnl",
  "pnl",
  "trade_count",
];
const sections = ["positions", "orders", "predictions"];
const display = formatAmount;
const when = formatDateTime;
export default class extends Component {
  @tracked query = "";
  @tracked result;
  @tracked sortKey = "equity";
  @tracked detail;
  @tracked error = "";
  @tracked busy = false;
  generation = 0;
  constructor() {
    super(...arguments);
    this.result = this.args.model;
  }
  @action async sort(event) {
    this.sortKey = event.target.value;
    await this.load(1);
  }
  @action async load(page) {
    this.busy = true;
    const generation = ++this.generation;
    try {
      const result = await ajax("/rsc/ranking.json", {
        data: { sort: this.sortKey, q: this.query, page },
      });
      if (generation === this.generation && !this.isDestroying) {
        this.result = result;
        this.error = "";
      }
    } catch (error) {
      if (!this.isDestroying) {
        this.error = extractError(error);
      }
    } finally {
      if (!this.isDestroying) {
        this.busy = false;
      }
    }
  }
  @action queryChanged(event) { this.query = event.target.value; }
  @action search(event) { event.preventDefault(); return this.load(1); }
  @action previous() {
    return this.load(this.result.pagination.page - 1);
  }
  @action next() {
    return this.load(this.result.pagination.page + 1);
  }
  get first() {
    return this.result.pagination.page <= 1;
  }
  get last() {
    return this.result.pagination.page >= this.result.pagination.pages;
  }
  get rankedRows() {
    return this.result.rows.map((row, i) => ({
      ...row,
      rank:
        (this.result.pagination.page - 1) * this.result.pagination.per_page +
        i +
        1,
    }));
  }
  @action async trader(id, section = "positions", page = 1) {
    this.busy = true;
    try {
      const detail = await ajax(`/rsc/traders/${id}.json`, {
        data: { section, page },
      });
      if (!this.isDestroying) {
        this.detail = detail;
        this.error = "";
      }
    } catch (error) {
      if (!this.isDestroying) {
        this.error = extractError(error);
      }
    } finally {
      if (!this.isDestroying) {
        this.busy = false;
      }
    }
  }
  @action openTrader(id) {
    return this.trader(id);
  }
  @action section(value) {
    return this.trader(this.detail.summary.user_id, value);
  }
  @action detailPage(page) { return this.trader(this.detail.summary.user_id, this.detail.section, page); }
  @action detailPrevious() {
    return this.trader(
      this.detail.summary.user_id,
      this.detail.section,
      this.detail.pagination.page - 1
    );
  }
  @action detailNext() {
    return this.trader(
      this.detail.summary.user_id,
      this.detail.section,
      this.detail.pagination.page + 1
    );
  }
  get detailFirst() {
    return this.detail.pagination.page <= 1;
  }
  get detailLast() {
    return this.detail.pagination.page >= this.detail.pagination.pages;
  }
  get performance() {
    const rows = this.detail?.performance?.points || [];
    // Do not connect across an unmeasurable zero-capital segment.
    const points = rows.filter((p) => p.return_pct !== null);
    if (points.length < 2) {
      return null;
    }
    const values = points.map((p) => Number(p.return_pct));
    const min = Math.min(...values),
      span = Math.max(...values) - min || 1;
    const start = Date.parse(points[0].at),
      end = Date.parse(points.at(-1).at);
    return {
      points: points
        .map(
          (p, i) =>
            `${20 + (560 * (Date.parse(p.at) - start)) / (end - start || 1)},${160 - (140 * (values[i] - min)) / span}`
        )
        .join(" "),
      start: formatDate(start),
      end: formatDate(end),
      last: points.at(-1).return_pct,
    };
  }
  <template>
    <main class="rsc-app rsc-ranking-page" aria-busy={{this.busy}}>
      <RscNavigation />
      <h1 class="sr-only">{{uiText "leaderboard"}}</h1>
      {{#if this.error}}<p
          class="alert alert-error"
          role="alert"
        >{{this.error}}</p>{{/if}}
      <section class="rsc-card"><form class="rsc-filter-bar rsc-ranking-search" {{on "submit" this.search}}><label>按用户名查找<input value={{this.query}} maxlength="60" {{on "input" this.queryChanged}} /></label><button type="submit" class="btn" disabled={{this.busy}}>查询</button><label>{{uiText "sort"}}<select
            disabled={{this.busy}}
            {{on "change" this.sort}}
          >{{#each sorts as |sort|}}<option
                value={{sort}}
                selected={{eq sort this.sortKey}}
              >{{uiText sort}}</option>{{/each}}</select></label></form>
        <div class="rsc-table"><table><thead><tr><th>{{uiText "rank"}}</th><th
                >{{uiText "username"}}</th><th>{{uiText "equity"}}</th><th
                >{{uiText "portfolio_equity"}}</th><th>{{uiText "realized_pnl"}}</th><th>{{uiText "pnl"}}</th><th
                >{{uiText "total_pnl"}}</th><th>{{uiText "return_pct"}}</th><th
                >{{uiText "trade_count"}}</th></tr></thead><tbody>
              {{#each this.rankedRows as |row|}}<tr><td><span
                      class="rsc-rank"
                      data-rank={{row.rank}}
                    >{{row.rank}}</span></td><td><button
                      class="btn btn-link rsc-trader-link"
                      type="button"
                      disabled={{this.busy}}
                      {{on "click" (fn this.openTrader row.user_id)}}
                    >{{row.username}}</button>{{#unless
                      (eq row.valuation_basis "current")
                    }}<small
                        class="rsc-valuation-note"
                        title={{when row.valuation_at}}
                      >{{uiText row.valuation_basis}}</small>{{/unless}}</td><td
                    title={{row.equity}}
                  >{{display row.equity}}</td><td title={{row.portfolio_equity}}>{{display row.portfolio_equity}}</td><td
                    title={{row.realized_pnl}}
                    class={{valueTone row.realized_pnl}}
                  >{{display row.realized_pnl}}</td><td
                    title={{row.pnl}}
                    class={{valueTone row.pnl}}
                  >{{display row.pnl}}</td><td
                    title={{row.total_pnl}}
                    class={{valueTone row.total_pnl}}
                  >{{display row.total_pnl}}</td><td>{{formatPercent
                      row.return_pct
                    }}</td><td>{{row.trade_count}}</td></tr>
              {{else}}<tr><td colspan="9">{{uiText "empty"}}</td></tr>{{/each}}
            </tbody></table></div>
        <RscPagination @page={{this.result.pagination}} @change={{this.load}} @busy={{this.busy}} />
      </section>
      {{#if this.detail}}<section
          class="rsc-card rsc-trader-detail"
          aria-label={{uiText "trader_detail"}}
        ><h2>{{this.detail.summary.username}} · {{uiText "trader_detail"}}</h2>
          <div class="rsc-market-summary"><div>{{uiText "equity"}}<strong
              >{{display this.detail.summary.equity}}</strong></div><div
            >{{uiText "total_pnl"}}<strong>{{display
                  this.detail.summary.total_pnl
                }}</strong></div><div>{{uiText "trade_count"}}<strong
              >{{this.detail.summary.trade_count}}</strong></div></div>
          <div class="rsc-chart-controls">{{#each sections as |section|}}<button
                type="button"
                class="btn
                  {{if (eq section this.detail.section) 'btn-primary'}}"
                disabled={{this.busy}}
                {{on "click" (fn this.section section)}}
              >{{if
                  (eq section "positions")
                  (uiText "trader_positions")
                  (uiText section)
                }}</button>{{/each}}</div>
          <div class="rsc-table"><table><thead><tr><th>{{uiText
                      "instrument"
                    }}</th><th>{{uiText "side"}}</th><th>{{uiText
                      "quantity"
                    }}</th><th>{{uiText "status"}}</th></tr></thead><tbody
              >{{#each this.detail.rows as |row|}}<tr><td>{{row.symbol}}</td><td
                    >{{uiText row.side}}</td><td
                      title={{row.quantity}}
                    >{{formatQuantity row.quantity}}</td><td>{{#if
                        row.status
                      }}{{uiText
                          row.status
                        }}{{else}}{{row.leverage}}×{{/if}}
                    {{#if row.equity}}<div>权益 {{display row.equity}} · 浮盈亏 {{display row.pnl}}</div>{{/if}}
                    {{#if row.price}}<div>成交 {{display row.price}} · 手续费 {{display row.fee}} · 盈亏 {{display row.pnl}}</div>{{/if}}
                    {{#if row.gross}}<div>名义金额 {{display row.gross}} RSC</div>{{/if}}
                    {{#if row.payout}}<div>返还 {{display row.payout}} RSC</div>{{/if}}
                    {{#if row.created_at}}<small>{{when row.created_at}}</small>{{/if}}</td></tr>{{else}}<tr
                  ><td colspan="4">{{uiText
                        "empty"
                      }}</td></tr>{{/each}}</tbody></table></div>
          <RscPagination @page={{this.detail.pagination}} @change={{this.detailPage}} @busy={{this.busy}} />
          {{#if this.performance}}<div class="rsc-history"><h3>{{uiText
                  "historical_performance"
                }}</h3><p class="rsc-muted">{{uiText
                  "performance_hint"
                }}</p><svg
                viewBox="0 0 600 180"
                role="img"
                aria-label={{uiText "historical_performance"}}
              ><polyline
                  points={{this.performance.points}}
                  fill="none"
                  stroke="currentColor"
                  stroke-width="2"
                /></svg><div class="rsc-chart-axis"><span
                >{{this.performance.start}}
                  →
                  {{this.performance.end}}</span><span>{{formatPercent
                    this.performance.last
                  }}</span></div></div>{{/if}}
        </section>{{/if}}
    </main>
  </template>
}
