import { formatAmount } from "../lib/rsc-format";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { service } from "@ember/service";
import { i18n } from "discourse-i18n";
const when = (value) => value ? new Date(value).toLocaleString() : "";
export default class extends Component {
  @service rscTips;
  @tracked data;
  constructor() {
    super(...arguments);
    this.updated = (event) => {
      if (event.detail.postId === this.args.post?.id) { this.load(true); }
    };
    document.addEventListener("rsc:tip-updated", this.updated);
    this.load();
  }
  willDestroy() {
    super.willDestroy(...arguments);
    document.removeEventListener("rsc:tip-updated", this.updated);
  }
  async load(refresh = false) {
    if (!this.args.post?.id || !this.args.post?.topic_id) { return; }
    try {
      const data = await this.rscTips.get(this.args.post, refresh);
      if (!this.isDestroying && !this.isDestroyed) { this.data = data; }
    } catch { /* Auxiliary summary must never prevent reading the post. */ }
  }
  <template>
    {{#if this.data.count}}
      <section class="rsc-post-tips" aria-label={{i18n "discourse_rsc.ui.tip_summary"}}>
        <div class="rsc-post-tips-heading">{{i18n "discourse_rsc.ui.tip_summary"}} · <strong title={{this.data.total}}>{{formatAmount this.data.total}} RSC</strong> · {{this.data.count}}</div>
        <ul>{{#each this.data.tips as |tip|}}
          <li><span>{{#if tip.user_url}}<a href={{tip.user_url}} data-user-card={{tip.username}} title={{when tip.at}}>{{tip.username}}</a>{{else}}{{tip.username}}{{/if}} × {{tip.count}}</span><strong title={{tip.amount}}>{{formatAmount tip.amount}} RSC</strong></li>
        {{/each}}</ul>
      </section>
    {{/if}}
  </template>
}
