import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { LinkTo } from "@ember/routing";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { formatAmount } from "../lib/rsc-format";
import { i18n } from "discourse-i18n";
const status = (value) => i18n(`discourse_rsc.ui.${value}`);
export default class extends Component {
  @tracked section = "sent";
  @tracked result;
  @tracked busy = false;
  @tracked error = "";
  constructor() { super(...arguments); this.load(1); }
  @action async select(section) { this.section = section; await this.load(1); }
  @action previous() { return this.load(this.result.pagination.page - 1); }
  @action next() { return this.load(this.result.pagination.page + 1); }
  get first() { return !this.result || this.result.pagination.page <= 1; }
  get last() { return !this.result || this.result.pagination.page >= this.result.pagination.pages; }
  async load(page) {
    if (this.busy) { return; }
    this.busy = true;
    try { const result = await ajax("/rsc/packets.json", { data: { section: this.section, page } }); if (!this.isDestroying) { this.result = result; this.error = ""; } }
    catch (error) { if (!this.isDestroying) { this.error = extractError(error); } }
    finally { if (!this.isDestroying) { this.busy = false; } }
  }
  <template>
    <section class="rsc-card rsc-packet-history"><h2>我的红包</h2><div class="rsc-chart-controls"><button type="button" class="btn" disabled={{this.busy}} {{on "click" (fn this.select "sent")}}>我发出的</button><button type="button" class="btn" disabled={{this.busy}} {{on "click" (fn this.select "received")}}>我领取的</button></div>
      {{#if this.error}}<p role="alert">{{this.error}}</p>{{/if}}
      {{#each this.result.rows as |packet|}}<p><LinkTo @route="rsc.packet" @model={{packet.token}}>{{packet.message}} · {{packet.sender}} · {{formatAmount packet.total}} RSC · {{packet.claimed_count}} / {{packet.count}} · {{status packet.status}}</LinkTo>{{#if packet.my_amount}}<strong> 领取 {{formatAmount packet.my_amount}} RSC</strong>{{/if}}</p>{{else}}<p class="rsc-muted">暂无红包记录</p>{{/each}}
      <div class="rsc-chart-controls"><button type="button" class="btn" disabled={{if this.busy true this.first}} {{on "click" this.previous}}>上一页</button><span>{{this.result.pagination.page}} / {{this.result.pagination.pages}}</span><button type="button" class="btn" disabled={{if this.busy true this.last}} {{on "click" this.next}}>下一页</button></div>
    </section>
  </template>
}
