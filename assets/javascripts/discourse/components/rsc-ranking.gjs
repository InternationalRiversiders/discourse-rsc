import { formatDateTime } from "../lib/campus-time";
import RscNavigation from "./rsc-navigation";
import RscPagination from "./rsc-pagination";
import ForumUser from "./rsc-user";
import { performanceChart } from "../lib/rsc-performance";
import dIcon from "discourse/ui-kit/helpers/d-icon";
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
const ranges = [{ days: 3, label: "近3天" }, { days: 7, label: "近一周" }, { days: 30, label: "近一月" }, { days: 0, label: "全部" }];
const sections = ["positions", "orders", "predictions"];
const display = formatAmount;
const when = formatDateTime;
export default class extends Component {
  @tracked query = "";
  @tracked result;
  @tracked sortKey = "equity";
  @tracked detail;
  @tracked activeTraderId = null;
  @tracked detailBusy = false;
  @tracked detailError = "";
  @tracked performanceDays = 0;
  detailGeneration = 0;
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
    this.closeTrader();
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
    const generation = ++this.detailGeneration;
    this.detailBusy = true;
    this.detailError = "";
    try {
      const detail = await ajax(`/rsc/traders/${id}.json`, { data: { section, page } });
      if (generation === this.detailGeneration && !this.isDestroying) {
        // Paginated responses omit the series; retain it for the same user.
        this.detail = { ...detail, performance: detail.performance ?? this.detail?.performance };
      }
    } catch (error) {
      if (generation === this.detailGeneration && !this.isDestroying) {
        this.detailError = extractError(error);
      }
    } finally {
      if (generation === this.detailGeneration && !this.isDestroying) {
        this.detailBusy = false;
      }
    }
  }
  @action closeTrader() {
    this.detailGeneration++;
    this.activeTraderId = null;
    this.detail = null;
    this.detailBusy = false;
    this.detailError = "";
  }
  @action openTrader(id) {
    if (this.activeTraderId === id) { return this.closeTrader(); }
    this.closeTrader();
    this.activeTraderId = id;
    this.performanceDays = 0;
    return this.trader(id);
  }
  @action performanceRange(days) { this.performanceDays = days; }
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
    return performanceChart(this.detail?.performance?.points, this.performanceDays);
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
        <div class="rsc-table rsc-ranking-table"><table><thead><tr><th>{{uiText "rank"}}</th><th
                >{{uiText "username"}}</th><th>{{uiText "equity"}}</th><th
                >{{uiText "portfolio_equity"}}</th><th>{{uiText "realized_pnl"}}</th><th>{{uiText "pnl"}}</th><th
                >{{uiText "total_pnl"}}</th><th>{{uiText "return_pct"}}</th><th
                >{{uiText "trade_count"}}</th></tr></thead><tbody>
              {{#each this.rankedRows key="user_id" as |row|}}<tr><td><span
                      class="rsc-rank"
                      data-rank={{row.rank}}
                    >{{row.rank}}</span></td><td><span class="rsc-ranked-user"><ForumUser @user={{row.forum_user}} @name={{row.username}} /><button
                      class="btn btn-flat btn-icon rsc-trader-link"
                      type="button"
                      title={{if (eq this.activeTraderId row.user_id) "收起持仓" "查看持仓"}}
                      aria-label={{if (eq this.activeTraderId row.user_id) "收起持仓" "查看持仓"}}
                      aria-expanded={{eq this.activeTraderId row.user_id}}
                      disabled={{this.busy}}
                      {{on "click" (fn this.openTrader row.user_id)}}
                    >{{dIcon "magnifying-glass"}}</button></span></td><td
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
      {{#if (eq this.activeTraderId row.user_id)}}<tr class="rsc-trader-expanded"><td colspan="9"><section
          class="rsc-trader-detail"
          aria-busy={{this.detailBusy}}
          aria-label={{uiText "trader_detail"}}
        ><div class="rsc-trader-heading"><h2><ForumUser @user={{row.forum_user}} @name={{row.username}} /> · {{uiText "trader_detail"}}</h2><button type="button" class="btn btn-flat" {{on "click" this.closeTrader}}>收起</button></div>
          {{#if this.detailError}}<p role="alert" class="alert alert-error">{{this.detailError}}</p>{{/if}}
          {{#if this.detailBusy}}<p role="status" class="rsc-muted">正在加载…</p>{{/if}}
          {{#if this.detail}}
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
                disabled={{this.detailBusy}}
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
          <RscPagination @page={{this.detail.pagination}} @change={{this.detailPage}} @busy={{this.detailBusy}} />
          <div class="rsc-performance">
            <div class="rsc-performance-heading"><h3>{{uiText "historical_performance"}}</h3>
              <div class="rsc-performance-ranges" role="group" aria-label="收益图时间范围">
                {{#each ranges as |range|}}<button type="button" class="btn {{if (eq range.days this.performanceDays) 'btn-primary'}}" aria-pressed={{eq range.days this.performanceDays}} {{on "click" (fn this.performanceRange range.days)}}>{{range.label}}</button>{{/each}}
              </div>
            </div>
            {{#if this.performance}}
              <svg viewBox="0 0 600 160" preserveAspectRatio="none" role="img" aria-label={{uiText "historical_performance"}}>
                {{#each this.performance.segments as |segment|}}<polyline points={{segment}} fill="none" stroke="currentColor" stroke-width="2" vector-effect="non-scaling-stroke" />{{/each}}
              </svg>
              <div class="rsc-chart-axis"><span>{{when this.performance.start}} → {{when this.performance.end}}</span><span>累计 {{formatPercent this.performance.last}}</span></div>
            {{else}}<p class="rsc-performance-empty">该时段没有足够的收益记录</p>{{/if}}
            <p class="rsc-muted rsc-performance-note">{{uiText "performance_hint"}}</p>
          </div>
          {{/if}}
        </section></td></tr>{{/if}}
              {{else}}<tr><td colspan="9">{{uiText "empty"}}</td></tr>{{/each}}
            </tbody></table></div>
        <RscPagination @page={{this.result.pagination}} @change={{this.load}} @busy={{this.busy}} />
      </section>
    </main>
  </template>
}
