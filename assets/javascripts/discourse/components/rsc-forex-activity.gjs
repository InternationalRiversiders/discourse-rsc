import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import dAvatar from "discourse/ui-kit/helpers/d-avatar";
import RscForexTrader from "./rsc-forex-trader";
import RscPagination from "./rsc-pagination";
import { formatDateTime } from "../lib/campus-time";
import { signedAmount } from "../lib/rsc-format";

const tone = (value) => Number(value) > 0 ? "positive" : Number(value) < 0 ? "negative" : "neutral";
const detailId = (id) => `rsc-fx-trader-${id}`;
export default class extends Component {
  @tracked activeTraderId = null;
  @tracked expanded = false;
  @tracked loading = false;
  @tracked data;
  @tracked error = "";
  @tracked endsDraft = "";
  @tracked saving = false;
  get status() { return this.args.activity?.active ? "进行中" : this.args.activity?.ended ? "已结束" : "尚未开放"; }
  get fee() { return Number(this.args.activity?.fee_bps || 0) / 100; }
  @action async toggle() {
    this.expanded = !this.expanded;
    this.activeTraderId = null;
    if (this.expanded) {
      const date = new Date(this.args.activity.ends_at);
      this.endsDraft = this.args.activity.ends_at && !Number.isNaN(date.getTime())
        ? new Date(date.getTime() - date.getTimezoneOffset() * 60000).toISOString().slice(0, 16) : "";
      await this.load(1);
    }
  }
  @action async load(page = 1) {
    if (this.loading) { return; }
    this.loading = true; this.error = "";
    try {
      const data = await ajax("/rsc/forex-activity.json", { data: { page } });
      if (!this.isDestroying && !this.isDestroyed) {
        this.data = data;
        if (!data.rows.some((row) => row.user_id === this.activeTraderId)) { this.activeTraderId = null; }
      }
    } catch (error) {
      if (!this.isDestroying && !this.isDestroyed) { this.error = extractError(error); }
    } finally {
      if (!this.isDestroying && !this.isDestroyed) { this.loading = false; }
    }
  }
  @action refreshBoard() { return this.load(this.data?.page || 1); }
  @action trader(id) { this.activeTraderId = this.activeTraderId === id ? null : id; }
  @action draft(event) { this.endsDraft = event.target.value; }
  @action async save(event) {
    event.preventDefault();
    if (this.saving || this.args.readOnly) { return; }
    const date = new Date(this.endsDraft);
    if (Number.isNaN(date.getTime())) { this.error = "请选择有效的结束时间。"; return; }
    this.saving = true; this.error = "";
    try {
      await ajax("/rsc/forex-activity/settings.json", { type: "POST", data: { ends_at: date.toISOString() } });
      await this.args.refresh();
      await this.load(1);
    } catch (error) {
      if (!this.isDestroying && !this.isDestroyed) { this.error = extractError(error); }
    } finally {
      if (!this.isDestroying && !this.isDestroyed) { this.saving = false; }
    }
  }
  <template>
    {{#if @activity.visible}}
      <section class="rsc-fx-activity" aria-label="久留美外汇活动">
        <div class="rsc-fx-banner">
          <div class="rsc-fx-emblem" aria-hidden="true">FX<span>100×</span></div>
          <div class="rsc-fx-intro"><div class="rsc-fx-title"><h2>{{@activity.title}}</h2><span class="rsc-fx-status">{{this.status}}</span></div>
            <p>外汇最高 100× · {{#if this.fee}}活动每边手续费 {{this.fee}}%{{else}}活动交易免手续费{{/if}} · 自动授予徽章与称号</p>
            <small>{{#if @activity.ends_at}}预计截止 {{formatDateTime @activity.ends_at}}（按你的时区显示，可随播出安排调整）{{else}}{{@activity.end_label}}{{/if}}</small>
          </div>
          <div class="rsc-fx-actions"><button class="btn btn-primary" type="button" {{on "click" @browse}}>外汇市场 {{dIcon "arrow-right"}}</button><button class="btn btn-flat" type="button" aria-expanded={{if this.expanded "true" "false"}} aria-controls="rsc-fx-standings" {{on "click" this.toggle}}>活动榜与规则 {{dIcon "chevron-down"}}</button></div>
        </div>
        {{#if this.expanded}}<div id="rsc-fx-standings" class="rsc-fx-content">
          <div class="rsc-fx-board-heading"><h3>外汇修行榜 <small>净盈亏 / RSC</small></h3><button class="btn btn-small" type="button" disabled={{this.loading}} {{on "click" this.refreshBoard}}>{{dIcon "arrows-rotate"}} 刷新</button></div>
          {{#if this.error}}<p class="alert alert-error" role="alert">{{this.error}}</p>{{/if}}
          {{#if this.data.me}}<p class="rsc-fx-mine">我的排名 <strong>#{{this.data.me.rank}}</strong> · 净盈亏 <strong class={{tone this.data.me.net}}>{{signedAmount this.data.me.net}}</strong> · 已修行 {{this.data.me.days}} 天</p>{{/if}}
          {{#if this.loading}}<p role="status">正在加载活动榜…</p>{{/if}}
          <ol class="rsc-fx-ranks" aria-label="活动排行榜">{{#each this.data.rows key="user_id" as |row|}}<li><span class="rsc-fx-rank">{{row.rank}}</span>
            {{#if row.forum_user.username}}<button type="button" class="rsc-forum-user rsc-fx-user-button" title="查看活动持仓与交易记录" aria-expanded={{if (eq this.activeTraderId row.user_id) "true" "false"}} aria-controls={{detailId row.user_id}} {{on "click" (fn this.trader row.user_id)}}>{{dAvatar row.forum_user imageSize="small" loading="lazy"}}<span>{{row.forum_user.username}}</span></button>{{else}}<span>已注销用户</span>{{/if}}
            <strong class={{tone row.net}}>{{signedAmount row.net}}</strong><small>{{row.days}} 天</small>
            {{#if (eq this.activeTraderId row.user_id)}}<RscForexTrader @id={{detailId row.user_id}} @userId={{row.user_id}} @username={{row.forum_user.username}} @close={{fn this.trader row.user_id}} />{{/if}}
          </li>{{else}}{{#unless this.loading}}<li class="rsc-fx-empty">尚无活动仓位，首次开仓成交后自动加入。</li>{{/unless}}{{/each}}</ol>
          {{#if this.data}}<RscPagination @page={{this.data}} @busy={{this.loading}} @change={{this.load}} />{{/if}}
          <details class="rsc-fx-rules"><summary>参与规则与奖励</summary>
            <ul><li>仅使用 RSC 的社区模拟交易活动。外汇活动期间可选 1–100×，没有额外冷却或持仓锁定；开仓等待新报价，平仓使用最新有效报价直接成交，不加随机滑点或额外保护价差；休市、行情过期及正常强平规则仍适用。</li>
              <li>活动外汇按钱包可用余额计算可开数量，不占用虚拟币的高杠杆保证金额度。比例按钮已考虑手续费和报价变化预留；补保证金只降低已有仓位的强平风险，不会增加数量。</li>
              <li>仅统计活动开始后新建的外汇仓位；活动前旧仓位及其加仓保留原费率，不进入活动榜。活动仓位可享后续降费，优惠费率保留至平仓，已扣费用不追溯调整。</li>
              <li>净盈亏包含已实现盈亏、开平仓手续费，以及未平仓按最近来源报价估值并扣除预计平仓费的盈亏。活动结束按截止前最后一笔可用来源报价冻结排名，行情可能存在延迟；不强制平仓。截止后只影响后续开仓，已有仓位仍可平仓、补保证金和设置止盈止损。</li>
              <li>盈利、亏损徽章按扣除手续费后的累计已实现净盈亏判断，不含浮盈浮亏；“活到完结”按截止时活动榜成绩判断。每枚徽章仅发一次，均可用作称号，无额外 RSC 奖励，无需申请或人工领取。</li>
            </ul>
            <dl class="rsc-fx-achievements">{{#each this.data.achievements key="key" as |badge|}}<div><dt>{{dIcon "award"}} {{badge.name}}</dt><dd>{{badge.description}}</dd></div>{{/each}}</dl>
          </details>
          {{#if @admin}}{{#unless @activity.ended}}<details class="rsc-fx-settings"><summary>调整活动结束时间</summary><form {{on "submit" this.save}}><label>结束时间（当前设备时区）<input type="datetime-local" required value={{this.endsDraft}} {{on "input" this.draft}} /></label><button class="btn" type="submit" disabled={{this.saving}}>保存时间</button></form><p class="rsc-muted">若动画停播或延期，请在原定截止前调整；已冻结的活动成绩不会重新计算。</p></details>{{/unless}}{{/if}}
        </div>{{/if}}
      </section>
    {{/if}}
  </template>
}
