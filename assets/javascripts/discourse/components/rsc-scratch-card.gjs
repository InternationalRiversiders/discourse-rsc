import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { modifier } from "ember-modifier";
import RscScratchSpot from "./rsc-scratch-spot";
import { createGameScene, supports3d } from "../lib/game-3d";

const money = (n) => Number(n || 0).toLocaleString("zh-CN", { maximumFractionDigits: 3 });
const ALL = Array.from({ length: 10 }, (_, i) => i);

// One card stays mounted across purchases so the WebGL ticket can fly the next one in;
// scratched spots are remembered per round id.
export default class extends Component {
  @tracked openedState = { round: null, list: [] };
  @tracked use3d = false;
  ctl = null;
  get serial() { return this.args.round?.id ?? null; }
  get opened() { return this.openedState.round === this.serial ? this.openedState.list : []; }
  get price() { return money(this.args.round?.stake ?? this.args.price); }
  get unit() { return money(this.args.round?.state.spot_stake ?? Number(this.args.price || 0) / 10); }
  get spots() {
    return (this.args.round?.state.spots || Array.from({ length: 10 }, () => ({}))).map((spot, i) => ({
      key: `${this.serial ?? "preview"}-${i}`, index: i, label: String(i + 1).padStart(2, "0"),
      payout: money(spot.payout), multiplier: spot.multiplier, won: Number(spot.payout) > 0,
    }));
  }
  get complete() { return this.args.revealed || this.opened.length === 10; }
  get payout() { return money(this.args.round?.payout); }
  get net() { const n = Number(this.args.round?.net || 0); return `${n > 0 ? "+" : ""}${money(n)}`; }
  get tone() { const n = Number(this.args.round?.net || 0); return n > 0 ? "win" : n < 0 ? "loss" : "push"; }
  get ticket() {
    return { purchased: !!this.args.round, serial: this.serial || 0, price: this.price, unit: this.unit,
      spots: this.spots.map(({ won, payout, multiplier }) => ({ won, payout, multiplier })) };
  }
  @action revealSpot(index) {
    if (this.opened.includes(index)) { return; }
    const list = [...this.opened, index];
    this.openedState = { round: this.serial, list };
    if (list.length === 10) { this.args.onReveal(); }
  }
  @action revealAll() { this.args.onReveal(); }

  scene = modifier((host) => {
    if (!supports3d("scratch")) { return; }
    let alive = true, ctl = null;
    createGameScene("scratch", host, { onSpot: (i) => this.revealSpot(i) }).then((c) => {
      if (!alive || this.isDestroying || this.isDestroyed) { c.dispose(); return; }
      ctl = this.ctl = c;
      c.setTicket(this.ticket, { opened: this.complete ? ALL : this.opened });
      this.use3d = true;
    }).catch(() => {});
    return () => { alive = false; ctl?.dispose(); if (this.ctl === ctl) { this.ctl = null; } };
  });
  // New purchase flies a fresh ticket in; completing the card wipes the rest and, on a win, throws coins.
  sync = modifier((host, [serial, complete]) => {
    const c = this.ctl;
    if (!c) { return; }
    c.setTicket(this.ticket, { animate: true, opened: complete ? ALL : this.opened });
    if (complete && serial) {
      const won = Number(this.args.round?.net) > 0;
      c.revealAll().then(() => { if (won && this.ctl === c) { c.celebrate(); } });
    }
  });

  <template>
    <div class="rg-large-ticket {{if this.use3d 'is-3d'}}">
      <div class="rg-3d rg-3d--scratch" role="img" aria-label="刮卡寻宝票面，可用鼠标或手指刮开" {{this.scene}} {{this.sync this.serial this.complete}}></div>
      <div class="rg-large-ticket-heading"><span>RIVERSIDE</span><span class="rg-ticket-price">{{this.price}} RSC</span></div>
      <div class="rg-large-ticket-title"><strong>刮卡寻宝</strong><span>十重好运</span></div>
      <div class="rg-large-ticket-meta">10 个开奖位 · 每位 {{this.unit}} RSC</div>
      <div class="rg-large-ticket-grid">
        {{#each this.spots key="key" as |spot|}}
          <RscScratchSpot @spot={{spot}} @purchased={{this.args.round}} @revealed={{this.complete}} @onReveal={{fn this.revealSpot spot.index}} />
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
