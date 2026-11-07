import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import RscScratchSpot from "./rsc-scratch-spot";

const money = (n) => Number(n || 0).toLocaleString("zh-CN", { maximumFractionDigits: 3 });

export default class extends Component {
  @tracked opened = [];
  get price() { return money(this.args.round?.stake ?? this.args.price); }
  get unit() { return money(this.args.round?.state.spot_stake ?? Number(this.args.price || 0) / 10); }
  get spots() {
    return (this.args.round?.state.spots || Array.from({ length: 10 }, () => ({}))).map((spot, i) => ({
      key: i, label: String(i + 1).padStart(2, "0"),
      payout: money(spot.payout), multiplier: spot.multiplier, won: Number(spot.payout) > 0,
    }));
  }
  get complete() { return this.args.revealed || this.opened.length === 10; }
  get payout() { return money(this.args.round?.payout); }
  get net() { const n = Number(this.args.round?.net || 0); return `${n > 0 ? "+" : ""}${money(n)}`; }
  get tone() { const n = Number(this.args.round?.net || 0); return n > 0 ? "win" : n < 0 ? "loss" : "push"; }
  @action revealSpot(key) {
    if (this.opened.includes(key)) { return; }
    this.opened = [...this.opened, key];
    if (this.opened.length === 10) { this.args.onReveal(); }
  }
  @action revealAll() { this.args.onReveal(); }

  <template>
    <div class="rg-large-ticket">
      <div class="rg-large-ticket-heading"><span>RIVERSIDE</span><span class="rg-ticket-price">{{this.price}} RSC</span></div>
      <div class="rg-large-ticket-title"><strong>幸运刮刮乐</strong><span>十重好运</span></div>
      <div class="rg-large-ticket-meta">10 个开奖位 · 每位 {{this.unit}} RSC</div>
      <div class="rg-large-ticket-grid">
        {{#each this.spots key="key" as |spot|}}
          <RscScratchSpot @spot={{spot}} @purchased={{this.args.round}} @revealed={{this.complete}} @onReveal={{fn this.revealSpot spot.key}} />
        {{/each}}
      </div>
      <div class="rg-large-ticket-footer">
        {{#if this.args.round}}
          {{#if this.complete}}
            <div class="rg-ticket-totals"><span>总返还 <strong>{{this.payout}} RSC</strong></span><span class="rg-{{this.tone}}">净收益 <strong>{{this.net}} RSC</strong></span></div>
          {{else}}
            <span>已刮开 {{this.opened.length}} / 10</span><button type="button" {{on "click" this.revealAll}}>全部刮开</button>
          {{/if}}
        {{else}}
          <span>购卡后刮开，十处奖金累加</span>
        {{/if}}
      </div>
    </div>
  </template>
}
