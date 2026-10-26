import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import RscPagination from "./rsc-pagination";
import { formatAmount, formatPrice, formatQuantity, signedAmount, valueTone } from "../lib/rsc-format";
import { formatDateTime } from "../lib/campus-time";

const sideName = (side) => i18n(`discourse_rsc.ui.${side}`);
export default class extends Component {
  @tracked data;
  @tracked section = "positions";
  @tracked busy = false;
  @tracked error = "";
  generation = 0;
  constructor() { super(...arguments); this.load(); }
  @action async load(page = 1) {
    const generation = ++this.generation;
    this.busy = true; this.error = "";
    try {
      const data = await ajax(`/rsc/forex-activity/traders/${this.args.userId}.json`, { data: { section: this.section, page } });
      if (!this.isDestroying && !this.isDestroyed && generation === this.generation) { this.data = data; }
    } catch (error) {
      if (!this.isDestroying && !this.isDestroyed && generation === this.generation) { this.error = extractError(error); }
    } finally {
      if (!this.isDestroying && !this.isDestroyed && generation === this.generation) { this.busy = false; }
    }
  }
  @action choose(section) { this.section = section; this.data = null; return this.load(); }
  <template>
    <section id={{@id}} class="rsc-fx-trader" aria-label="活动外汇交易档案" aria-busy={{if this.busy "true" "false"}}>
      <div class="rsc-fx-trader-heading"><h4>{{@username}} · 活动外汇</h4><button class="btn btn-flat" type="button" {{on "click" @close}}>收起</button></div>
      <div class="rsc-chart-controls" role="group" aria-label="活动交易记录类型">
        <button class="btn {{if (eq this.section 'positions') 'btn-primary'}}" type="button" disabled={{this.busy}} aria-pressed={{if (eq this.section 'positions') "true" "false"}} {{on "click" (fn this.choose "positions")}}>持仓</button>
        <button class="btn {{if (eq this.section 'orders') 'btn-primary'}}" type="button" disabled={{this.busy}} aria-pressed={{if (eq this.section 'orders') "true" "false"}} {{on "click" (fn this.choose "orders")}}>交易记录</button>
      </div>
      {{#if this.busy}}<p role="status">正在加载活动交易…</p>{{/if}}
      {{#if this.error}}<p class="alert alert-error" role="alert">{{this.error}}</p><button type="button" class="btn btn-small" {{on "click" (fn this.load 1)}}>重试</button>{{/if}}
      {{#if this.data}}
        <p class="rsc-fx-trader-summary">活动净盈亏 <strong class={{valueTone this.data.summary.net}}>{{signedAmount this.data.summary.net}} RSC</strong> · 持仓 {{this.data.summary.position_count}} · 成交 {{this.data.summary.trade_count}} 笔</p>
        <div class="rsc-fx-trades">{{#each this.data.rows key="id" as |trade|}}
          <article class="rsc-fx-trade">
            <div class="rsc-fx-trade-heading"><span><b>{{trade.display_symbol}}</b> {{trade.currency_name}} · {{sideName trade.side}} {{trade.leverage}}×{{#if trade.reason}} · {{sideName trade.reason}}{{/if}}</span>{{#if trade.executed_at}}<time>{{formatDateTime trade.executed_at}}</time>{{/if}}</div>
            <dl><div><dt>数量</dt><dd title={{trade.quantity}}>{{formatQuantity trade.quantity}}</dd></div>
              {{#if (eq this.section "positions")}}
                <div><dt>持仓均价</dt><dd title={{trade.average}}>{{formatPrice trade.average}}</dd></div>
                <div><dt>保证金 / RSC</dt><dd>{{formatAmount trade.margin}}</dd></div>
                <div><dt>持仓权益 / RSC</dt><dd>{{formatAmount trade.equity}}</dd></div>
                <div><dt>浮动盈亏 / RSC</dt><dd class={{valueTone trade.pnl}}>{{signedAmount trade.pnl}}</dd></div>
              {{else}}
                <div><dt>成交价</dt><dd title={{trade.price}}>{{formatPrice trade.price}}</dd></div>
                <div><dt>手续费 / RSC</dt><dd>{{formatAmount trade.fee}}</dd></div>
                {{#if (eq trade.side "close")}}<div><dt>平仓盈亏 / RSC</dt><dd class={{valueTone trade.pnl}}>{{signedAmount trade.pnl}}</dd></div>{{/if}}
              {{/if}}
            </dl>
            {{#if trade.valuation_at}}<small class="rsc-muted">估值时间 {{formatDateTime trade.valuation_at}}</small>{{/if}}
          </article>
        {{else}}<p class="rsc-muted">{{if (eq this.section "positions") "暂无未平仓的活动持仓" "暂无活动期间的成交记录"}}</p>{{/each}}</div>
        <RscPagination @page={{this.data.pagination}} @busy={{this.busy}} @change={{this.load}} />
        <p class="rsc-muted rsc-fx-trader-note">仅展示本次活动仓位及活动期间的成交；活动前旧仓位不计入。活动净盈亏按活动榜口径计算。</p>
      {{/if}}
    </section>
  </template>
}
