import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import { formatAmount } from "../lib/rsc-format";
const when = (value) => value ? new Date(value).toLocaleString() : "—";
const uiText = (key) => i18n(`discourse_rsc.ui.${key}`, { defaultValue: key });
export default class extends Component {
  @tracked entries = [];
  @tracked category = "all";
  @tracked cursor;
  @tracked more = true;
  @tracked busy = false;
  @tracked error = "";
  constructor() { super(...arguments); if (this.args.journalId) { this.load(); } }
  @action async select(event) {
    this.category = event.target.value;
    this.entries = []; this.cursor = null; this.more = true;
    await this.load();
  }
  @action opened(event) { if (event.target.open && !this.entries.length) { this.load(); } }
  @action async load() {
    if (this.busy) { return; }
    this.busy = true;
    try {
      const data = await ajax("/rsc/history.json", { data: { category: this.category, ...(this.args.journalId ? { journal_id: this.args.journalId } : {}), ...(this.cursor ? { cursor: this.cursor } : {}) } });
      this.entries = [...new Map([...(data.focused_entry ? [data.focused_entry] : []), ...this.entries, ...data.entries].map((row) => [row.id, row])).values()];
      this.cursor = data.next_cursor; this.more = !!data.next_cursor; this.error = "";
    } catch (error) { this.error = extractError(error); } finally { this.busy = false; }
  }
  <template>
    <details open={{this.args.journalId}} class="rsc-card rsc-wallet-history" {{on "toggle" this.opened}}><summary>{{uiText "full_history"}}</summary>
      <div class="rsc-chart-controls"><label>流水分类 <select disabled={{this.busy}} {{on "change" this.select}}><option value="all">全部流水</option><option value="payout">每日活跃奖励</option><option value="activity">其他活动与交易</option></select></label></div>
      {{#if this.error}}<p role="alert">{{this.error}}</p>{{/if}}
      <div class="rsc-scroll"><table><thead><tr><th>时间</th><th>类型 / 对方 / 说明</th><th>收支</th><th>余额</th></tr></thead><tbody>
        {{#each this.entries key="id" as |entry|}}<tr id={{entry.anchor}}><td>{{when entry.created_at}}</td><td>{{uiText entry.operation}}{{#if entry.counterparty}}<div>{{#if entry.counterparty.url}}<a href={{entry.counterparty.url}} data-user-card={{entry.counterparty.username}}>{{entry.counterparty.username}}</a>{{else}}{{entry.counterparty.username}}{{/if}}</div>{{/if}}{{#if entry.detail}}<small>{{entry.detail}}</small>{{/if}}{{#if entry.path}}<div><a href={{entry.path}}>查看相关记录 ↗</a></div>{{/if}}</td><td title={{entry.amount}}>{{uiText entry.direction}} {{formatAmount entry.amount}}</td><td title={{entry.balance_after}}>{{formatAmount entry.balance_after}}</td></tr>{{else}}<tr><td colspan="4">暂无流水</td></tr>{{/each}}
      </tbody></table></div>
      {{#if this.more}}<button class="btn" type="button" disabled={{this.busy}} {{on "click" this.load}}>{{uiText "load_more"}}</button>{{/if}}
    </details>
  </template>
}
