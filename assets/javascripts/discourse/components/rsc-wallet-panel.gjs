import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { formatAmount } from "../lib/rsc-format";
const uiText = (value) => i18n(`discourse_rsc.ui.${value}`);
import { service } from "@ember/service";
import RscPackets from "./rsc-packets";
import RscLedger from "./rsc-ledger";
export default class RscWalletPanel extends Component {
  @service router;
  @tracked recipient = "";
  @tracked amount = "";
  @tracked packetAmount = "1";
  @tracked packetCount = "5";
  @tracked packetMode = "fixed";
  @tracked packetMessage = "";
  @tracked packetDays = "1";
  @tracked packetMinimum = "0.01";
  @tracked packetMaximum = "100";
  get data() { return this.args.data; }
  get ledgerRevision() { return this.data.entries[0]?.id; }
  get writeDisabled() { return this.args.busy || this.data.read_only || this.data.wallet.status !== "active"; }
  @action set(field, event) { this[field] = event.target.value; }
  @action transfer(event) {
    event.preventDefault();
    return this.args.send("transfers", {
      recipient_username: this.recipient,
      amount: this.amount,
    });
  }
  @action async createPacket(event) {
    event.preventDefault();
    const result = await this.args.send("packets", {
      mode: this.packetMode,
      count: this.packetCount,
      amount: this.packetAmount,
      message: this.packetMessage,
      days: this.packetDays,
      minimum: this.packetMinimum,
      maximum: this.packetMode === "random" ? this.packetMaximum : undefined,
    });
    if (result && !this.isDestroying && !this.isDestroyed) {
      this.router.transitionTo("rsc.packet", result.token);
    }
  }

  get rewardPosts() { return Math.min(this.data.reward.posts, 10); }

  <template>
        <section class="rsc-card rsc-reward-summary"><h2>{{uiText
              "today_reward"
            }}
            ·
            {{this.data.reward.date}}</h2><div class="rsc-market-summary"><div
            ><span>{{uiText "reward_login"}}</span><strong
              >{{this.data.reward.login_reward}} RSC</strong></div><div><span>{{uiText
                  "reward_streak"
                }}</span><strong>{{this.data.reward.login_streak}}</strong></div><div><span>{{uiText "reward_posts"}}</span><strong>{{this.rewardPosts}} / 10</strong></div><div
            ><span>{{uiText "estimated_reward"}}</span><strong>{{formatAmount
                  this.data.reward.estimated
                }}
                RSC</strong></div></div>{{#unless this.data.reward.enabled}}<p
              class="rsc-muted"
            >{{uiText "rewards_disabled"}}</p>{{/unless}}</section>
        <div class="rsc-grid">
          <section class="rsc-card rsc-transfer-card"><div
              class="rsc-section-label"
            ><span aria-hidden="true">↗</span>TRANSFER</div><h2>{{uiText
                "transfer"
              }}</h2><form {{on "submit" this.transfer}}>
              <label>{{uiText "recipient"}}<input
                  required
                  value={{this.recipient}}
                  {{on "input" (fn this.set "recipient")}}
                  autocomplete="off"
                /></label>
              <label>{{uiText "amount"}}<input
                  required
                  inputmode="decimal"
                  value={{this.amount}}
                  {{on "input" (fn this.set "amount")}}
                  placeholder="0.00"
                /></label>
              <button
                class="btn btn-primary"
                type="submit"
                disabled={{this.writeDisabled}}
              >{{uiText "transfer"}}</button>
            </form></section>
          <section class="rsc-card rsc-create-packet-card"><div
              class="rsc-section-label"
            ><span aria-hidden="true">✉</span>RED PACKET</div><h2>{{uiText
                "create_packet"
              }}</h2><form {{on "submit" this.createPacket}}>
              <label>{{uiText "packet_mode"}}<select
                  {{on "change" (fn this.set "packetMode")}}
                ><option value="fixed">{{uiText "fixed"}}</option><option
                    value="random"
                  >{{uiText "random"}}</option></select></label>
              <div class="rsc-fields"><label>{{#if
                    (eq this.packetMode "fixed")
                  }}{{uiText "per_share"}}{{else}}{{uiText
                      "total"
                    }}{{/if}}<input
                    required
                    inputmode="decimal"
                    value={{this.packetAmount}}
                    {{on "input" (fn this.set "packetAmount")}}
                  /></label><label>{{uiText "count"}}<input
                    required
                    inputmode="numeric"
                    value={{this.packetCount}}
                    {{on "input" (fn this.set "packetCount")}}
                  /></label></div>
              <div class="rsc-fields"><label>{{uiText "packet_days"}}<select
                    {{on "change" (fn this.set "packetDays")}}
                  ><option value="1">1</option><option
                      value="3"
                    >3</option><option value="5">5</option><option
                      value="7"
                    >7</option><option
                      value="30"
                    >30</option></select></label></div>
              {{#if (eq this.packetMode "random")}}<div
                  class="rsc-fields"
                ><label>{{uiText "packet_minimum"}}<input
                      required
                      inputmode="decimal"
                      value={{this.packetMinimum}}
                      {{on "input" (fn this.set "packetMinimum")}}
                    /></label><label>{{uiText "packet_maximum"}}<input
                      required
                      inputmode="decimal"
                      value={{this.packetMaximum}}
                      {{on "input" (fn this.set "packetMaximum")}}
                    /></label></div>{{/if}}
              <label>{{uiText "message"}}<input
                  maxlength="80"
                  value={{this.packetMessage}}
                  {{on "input" (fn this.set "packetMessage")}}
                /></label><button
                class="btn btn-primary"
                type="submit"
                disabled={{this.writeDisabled}}
              >{{uiText "create_packet"}}</button>
            </form></section>
        </div>
        <RscPackets />
        <RscLedger @journalId={{@focus.journal_id}} @revision={{this.ledgerRevision}} />
  </template>
}
