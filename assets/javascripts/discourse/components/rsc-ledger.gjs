import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import { formatAmount, signedAmount, valueTone } from "../lib/rsc-format";
const when = (value) => value ? new Date(value).toLocaleString() : "—";
const uiText = (key) => i18n(`discourse_rsc.ui.${key}`, { defaultValue: key });
export default class extends Component {
  @tracked entries = [];
  @tracked category = "all";
  @tracked cursor;
  @tracked more = true;
  @tracked busy = false;
  @tracked error = "";
  refreshPending = false;
  constructor() { super(...arguments); this.load(); }
  @action refresh() {
    if (this.busy) { this.refreshPending = true; return; }
    this.entries = []; this.cursor = null; this.more = true;
    return this.load();
  }
  @action async select(event) {
    this.category = event.target.value;
    this.entries = []; this.cursor = null; this.more = true;
    await this.load();
  }
  @action async load() {
    if (this.busy) { return; }
    this.busy = true;
    try {
      const data = await ajax("/rsc/history.json", { data: { per_page: 20, category: this.category, ...(this.args.journalId ? { journal_id: this.args.journalId } : {}), ...(this.cursor ? { cursor: this.cursor } : {}) } });
      if (this.isDestroying || this.isDestroyed) { return; }
      this.entries = [...new Map([...(data.focused_entry ? [data.focused_entry] : []), ...this.entries, ...data.entries].map((row) => [row.id, row])).values()];
      this.cursor = data.next_cursor; this.more = !!data.next_cursor; this.error = "";
    } catch (error) { if (!this.isDestroying && !this.isDestroyed) { this.error = extractError(error); } } finally {
      if (!this.isDestroying && !this.isDestroyed) {
        this.busy = false;
        if (this.refreshPending) { this.refreshPending = false; this.refresh(); }
      }
    }
  }
  <template>
    <section class="rsc-card rsc-wallet-history" {{didUpdate this.refresh @revision}}><div class="rsc-history-heading"><h2>{{uiText "history"}}</h2><span class="rsc-muted">最新记录在前</span></div>
      <div class="rsc-filter-bar"><label>流水分类 <select disabled={{this.busy}} {{on "change" this.select}}><option value="all">全部流水</option><option value="payout">每日活跃奖励</option><option value="activity">其他活动与交易</option></select></label></div>
      {{#if this.error}}<p role="alert">{{this.error}}</p>{{/if}}
      <div class="rsc-scroll"><table class="rsc-compact-table"><thead><tr><th>时间</th><th>类型 / 对方 / 说明</th><th>收支</th><th>余额</th></tr></thead><tbody>
        {{#each this.entries key="id" as |entry|}}<tr id={{entry.anchor}}><td>{{when entry.created_at}}</td><td>{{uiText entry.operation}}{{#if entry.counterparty}}<div>{{#if entry.counterparty.url}}<a href={{entry.counterparty.url}} data-user-card={{entry.counterparty.username}}>{{entry.counterparty.username}}</a>{{else}}{{entry.counterparty.username}}{{/if}}</div>{{/if}}{{#if entry.detail}}<small>{{entry.detail}}</small>{{/if}}{{#if entry.path}}<div><a href={{entry.path}}>查看相关记录 ↗</a></div>{{/if}}</td><td class={{valueTone entry.amount}} title={{entry.amount}}>{{signedAmount entry.amount}}</td><td title={{entry.balance_after}}>{{formatAmount entry.balance_after}}</td></tr>{{else}}<tr><td colspan="4">暂无流水</td></tr>{{/each}}
      </tbody></table></div>
      {{#if this.more}}<button class="btn" type="button" disabled={{this.busy}} {{on "click" this.load}}>加载更早记录</button>{{/if}}
    </section>
  </template>
}
