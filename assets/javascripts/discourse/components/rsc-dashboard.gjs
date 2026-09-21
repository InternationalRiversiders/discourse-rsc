import RscNavigation from "./rsc-navigation";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { fn, array } from "@ember/helper";
import { LinkTo } from "@ember/routing";
import { eq, not } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import RscPackets from "./rsc-packets";
import RscLedger from "./rsc-ledger";
import RscHistory from "./rsc-history";
import RscDiscovery from "./rsc-discovery";
import RscMarketList from "./rsc-market-list";
import {
  formatAmount,
  formatWallet,
  formatQuantity,
  formatPrice,
} from "../lib/rsc-format";
import { estimate, payout } from "../lib/rsc-estimate";
import { marketView } from "../lib/rsc-market";
import { i18n } from "discourse-i18n";

const uiText = (value) => i18n(`discourse_rsc.ui.${value}`);
const pretty = formatAmount;
const displayAmount = formatWallet;
const initials = (value) =>
  Array.from(value || "")
    .slice(0, 2)
    .join("");
const tone = (value) =>
  Number(value) > 0 ? "positive" : Number(value) < 0 ? "negative" : "neutral";
const when = (value) => (value ? new Date(value).toLocaleString() : "—");
// Numbers are used only for the chart's pixels. Monetary requests remain strings.
const points = (history) => {
  const values = (history || [])
    .map((item) => Number(item.price))
    .filter(Number.isFinite);
  if (values.length < 2) {
    return "";
  }
  const min = Math.min(...values),
    span = Math.max(...values) - min || 1;
  return values
    .map(
      (value, index) =>
        `${(index * 600) / (values.length - 1)},${130 - ((value - min) * 110) / span}`
    )
    .join(" ");
};

export default class RscDashboard extends Component {
  @service router;
  @tracked snapshot;
  @tracked busy = false;
  @tracked notice = "";
  @tracked error = "";
  @tracked selectedId = "";
  @tracked marketDetailOpen = false;
  @tracked quoteClock = Date.now();
  @tracked recipient = "";
  @tracked amount = "";
  @tracked quantity = "1";
  @tracked leverage = "1";
  @tracked side = "long";
  @tracked highRisk = false;
  @tracked margins = {};
  @tracked stake = "10";
  @tracked packetAmount = "1";
  @tracked packetCount = "5";
  @tracked packetMode = "fixed";
  @tracked packetMessage = "";
  @tracked packetDays = "1";
  @tracked packetMinimum = "0.01";
  @tracked packetMaximum = "100";
  @tracked league = "all";
  @tracked predictionDrafts = {};
  @tracked protections = {};
  @tracked closeQuantities = {};
  @tracked takeProfit = "";
  @tracked stopLoss = "";
  @tracked sport = "all";
  @tracked matchFilter = "open";
  timer;
  requestIds = new Map();

  constructor() {
    super(...arguments);
    const requested = this.args.model.focus?.instrument_id;
    if (requested && this.args.model.instruments.some((item) => String(item.id) === requested)) { this.selectMarket(requested); }
    if (!requested && this.selected) {
      const position = this.data.positions.find((item) => item.instrument_id === this.selected.id);
      this.quantity = this.selected.minimum || "1";
      this.leverage = String(position?.leverage || 1);
      this.side = position?.side || "long";
    }
    if (this.args.model.focus?.match_id) { this.matchFilter = "all"; }
    this.timer = setInterval(() => {
      if (!document.hidden && !this.busy) {
        this.quoteClock = Date.now();
        this.refresh().catch(() => {});
      }
    }, 15000);
  }
  willDestroy() {
    super.willDestroy(...arguments);
    clearInterval(this.timer);
  }
  get data() {
    return this.snapshot || this.args.model;
  }
  get selected() {
    return (
      this.data.instruments.find(
        (item) => String(item.id) === this.selectedId
      ) || this.data.instruments[0]
    );
  }
  get selectedMarket() {
    return this.selected && marketView(this.selected, this.quoteClock);
  }
  get writeDisabled() { return this.busy || this.data.read_only || this.data.wallet.status !== "active"; }
  get tradingDisabled() {
    return (
      this.data.read_only ||
      this.busy ||
      !this.selectedMarket?.tradable ||
      this.data.wallet.status !== "active" ||
      (this.side !== "close" && this.selected?.close_only)
    );
  }
  @action selectMarket(id) {
    this.selectedId = String(id);
    this.marketDetailOpen = true;
    this.quantity = this.selected?.minimum || "1";
    const position = this.data.positions.find((item) => String(item.instrument_id) === String(id));
    this.leverage = String(position?.leverage || 1);
    this.side = position?.side || "long";
    this.takeProfit = ""; this.stopLoss = "";
    this.notice = "";
    this.error = "";
    Promise.resolve().then(() => {
      if (!this.isDestroying && !this.isDestroyed) {
        return this.refresh();
      }
    }).catch(() => {});
  }
  @action quickTrade(id, side) {
    this.selectMarket(id);
    this.side = side;
    requestAnimationFrame(() =>
      document.querySelector(".rsc-order-ticket input")?.focus()
    );
  }
  @action toggleHighRisk(event) {
    this.highRisk = event.target.checked;
    if (!this.highRisk && Number(this.leverage) > 10) {
      this.leverage = "10";
    }
  }
  get estimate() { return estimate(this.selected, this.quantity, this.leverage, this.data.wallet.balance); }
  @action maximum() { if (this.estimate) { this.quantity = this.estimate.maximum; } }
  @action closeQuantity(id, event) { this.closeQuantities = { ...this.closeQuantities, [id]: event.target.value }; }
  get maxLeverage() {
    return this.highRisk &&
      this.data.high_risk_enabled &&
      this.selected?.category === "crypto"
      ? 100
      : 10;
  }
  @action marginDraft(id, event) {
    this.margins = { ...this.margins, [id]: event.target.value };
  }
  @action addMargin(position, event) {
    event.preventDefault();
    return this.send(`positions/${position.id}/margin`, {
      amount: this.margins[position.id],
    });
  }
  @action backToMarkets() {
    this.marketDetailOpen = false;
  }
  get leagues() {
    return [...new Map(this.data.matches.map((match) => [match.league, { id: match.league, label: match.league_name || match.league }])).values()];
  }
  get matches() {
    return this.data.matches
      .filter((match) => (this.league === "all" || match.league === this.league) && (this.sport === "all" || match.sport === this.sport))
      .filter((match) => this.matchFilter === "all" || (this.matchFilter === "mine" && !!match.prediction) || (this.matchFilter === "open" && !match.locked_reason) || (this.matchFilter === "closed" && !!match.locked_reason && ["live","finished","canceled"].includes(match.status)) || (this.matchFilter === "unavailable" && !!match.locked_reason && ["scheduled","postponed"].includes(match.status)) || (this.matchFilter === "popular" && match.participants > 0))
      .sort((a,b) => this.matchFilter === "popular" ? b.participants-a.participants : 0)
      .map((match) => {
        const prediction = match.prediction;
        const draft = this.predictionDrafts[match.id] || {};
        const fresh =
          match.odds_at &&
          Date.now() - Date.parse(match.odds_at) <=
            this.data.odds_max_age_hours * 3600000;
        return {
          ...match,
          prediction,
          draftStake: draft.stake ?? prediction?.stake ?? this.stake,
          draftPick: draft.pick ?? prediction?.pick ?? "home",
          potentialPayout: payout(draft.stake ?? prediction?.stake ?? this.stake, match.odds[draft.pick ?? prediction?.pick ?? "home"]),
          locked:
            this.data.read_only || this.data.wallet.status !== "active" ||
            match.status !== "scheduled" ||
            Date.parse(match.starts_at) <= Date.now() ||
            !fresh,
          choices: ["home", ...(match.allow_draw ? ["draw"] : []), "away"]
            .filter((pick) => match.odds[pick])
            .map((pick) => ({
              pick,
              title: uiText(pick),
              odds: match.odds[pick],
            })),
        };
      });
  }
  get positions() {
    return this.data.positions.map((position) => ({
      ...position,
      closeQuantity: this.closeQuantities[position.id] ?? position.quantity,
      remaining: position.hold_until ? Math.max(0, Math.ceil((Date.parse(position.hold_until) - this.quoteClock) / 1000)) : 0,
      closeDisabled: this.busy || this.data.read_only || this.data.wallet.status !== "active" || (position.hold_until && Date.parse(position.hold_until) > this.quoteClock),
      tp: this.protections[position.id]?.tp ?? position.take_profit ?? "",
      sl: this.protections[position.id]?.sl ?? position.stop_loss ?? "",
    }));
  }
  @action set(field, event) {
    this[field] = event.target.value;
  }
  @action draft(matchId, field, event) {
    this.predictionDrafts = {
      ...this.predictionDrafts,
      [matchId]: {
        ...this.predictionDrafts[matchId],
        [field]: event.target.value,
      },
    };
  }
  @action protection(positionId, field, event) {
    this.protections = {
      ...this.protections,
      [positionId]: {
        ...this.protections[positionId],
        [field]: event.target.value,
      },
    };
  }
  @action async refresh() {
    if (this.refreshing) {
      return this.refreshing;
    }
    this.refreshing = this.loadState();
    try {
      await this.refreshing;
    } finally {
      this.refreshing = null;
    }
  }
  async loadState() {
    if (this.args.section === "market" && this.marketDetailOpen &&
        this.selected && this.data.market_data_enabled && !this.data.read_only) {
      await ajax(`/rsc/instruments/${this.selected.id}/refresh.json`, { type: "POST" }).catch(() => {});
    }
    const state = await ajax("/rsc/state.json", { data: this.args.model.focus || {} });
    if (this.args.model.packet) {
      state.packet = await ajax(
        `/rsc/packet/${this.args.model.packet.token}.json`
      );
    }
    if (!this.isDestroying && !this.isDestroyed) {
      this.snapshot = state;
    }
  }
  async send(path, data) {
    if (this.data.read_only) {
      this.error = uiText("read_only");
      return;
    }
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.error = "";
    this.notice = "";
    const key = JSON.stringify([path, data]);
    const requestId = this.requestIds.get(key) || crypto.randomUUID();
    this.requestIds.set(key, requestId);
    try {
      const result = await ajax(`/rsc/${path}.json`, {
        type: "POST",
        data: { ...data, request_id: requestId },
      });
      this.requestIds.delete(key);
      this.notice = uiText("saved");
      await this.refresh().catch(() => {});
      return result;
    } catch (error) {
      this.error = extractError(error);
    } finally {
      this.busy = false;
    }
  }
  @action transfer(event) {
    event.preventDefault();
    return this.send("transfers", {
      recipient_username: this.recipient,
      amount: this.amount,
    });
  }
  @action trade(event) {
    event.preventDefault();
    return this.send("orders", {
      instrument_id: this.selected.id,
      side: this.side,
      quantity: this.quantity,
      leverage: this.leverage,
      high_risk: this.highRisk,
      take_profit: this.side === "close" ? "" : this.takeProfit,
      stop_loss: this.side === "close" ? "" : this.stopLoss,
    });
  }
  @action close(position, event) {
    event?.preventDefault();
    return this.send("orders", {
      instrument_id: position.instrument_id,
      side: "close",
      quantity: position.closeQuantity || position.quantity,
      leverage: String(position.leverage),
    });
  }
  @action cancel(order) {
    return this.send(`orders/${order.id}/cancel`, {});
  }
  @action protect(position, event) {
    event.preventDefault();
    return this.send(`positions/${position.id}/protection`, {
      take_profit: position.tp,
      stop_loss: position.sl,
    });
  }
  @action predict(match, event) {
    event.preventDefault();
    return this.send("predictions", {
      match_id: match.id,
      prediction_id: match.prediction?.id || "",
      pick: match.draftPick,
      stake: match.draftStake,
    });
  }
  @action async createPacket(event) {
    event.preventDefault();
    const result = await this.send("packets", {
      mode: this.packetMode,
      count: this.packetCount,
      amount: this.packetAmount,
      message: this.packetMessage,
      days: this.packetDays,
      minimum: this.packetMinimum,
      maximum: this.packetMode === "random" ? this.packetMaximum : undefined,
    });
    if (result) {
      this.router.transitionTo("rsc.packet", result.token);
    }
  }
  @action async copyPacket() {
    try { await navigator.clipboard.writeText(`${window.location.origin}/rsc/packets/${this.data.packet.token}`); this.notice = "红包链接已复制"; }
    catch { this.error = `请复制这个链接：${window.location.origin}/rsc/packets/${this.data.packet.token}`; }
  }
  @action claim() {
    return this.send(`packet/${this.data.packet.token}/claim`, {});
  }
  @action closePacket() {
    return this.send(`packet/${this.data.packet.token}/close`, {});
  }

  <template>
    {{#if this.data.read_only}}<p
        class="alert alert-info rsc-read-only"
        role="status"
      >{{uiText "read_only"}}</p>{{/if}}
    <main class="rsc-app" data-section={{@section}}>
      <RscNavigation />
      {{#if this.data.wallet.status_reason}}<p class="alert alert-info">账户已冻结：{{this.data.wallet.status_reason}}</p>{{/if}}
      <header class="rsc-heading">
        <div class="rsc-heading-copy"><p class="rsc-eyebrow"><span
              class="rsc-brand-mark"
              aria-hidden="true"
            >R</span>RIVERSIDE COIN</p>
          <h1>{{#if (eq @section "market")}}{{uiText "exchange_title"}}{{else if
              (eq @section "sports")
            }}{{uiText "sports"}}{{else}}{{uiText "title"}}{{/if}}</h1>
          <p class="rsc-heading-description">{{#if
              (eq @section "market")
            }}{{uiText "market_intro"}}{{else if
              (eq @section "sports")
            }}{{uiText "sports_intro"}}{{else}}{{uiText
                "wallet_intro"
              }}{{/if}}</p>
        </div>
        <div class="rsc-balance"><span>{{uiText "available"}}<span
              class="rsc-balance-dot"
              aria-hidden="true"
            ></span></span><strong
            title={{this.data.wallet.balance}}
          >{{displayAmount this.data.wallet.balance}}
            <small>RSC</small></strong><span
            class="rsc-balance-caption"
          >RIVERSIDE / WALLET</span></div>
      </header>
      {{#if this.data.demo}}<p class="rsc-trial">{{uiText "trial"}}</p>{{/if}}

      {{#if this.error}}<div
          class="alert alert-error"
          role="alert"
        >{{this.error}}</div>{{/if}}
      {{#if this.notice}}<div
          class="alert alert-success"
          role="status"
        >{{this.notice}}</div>{{/if}}
      {{#if (eq @section "wallet")}}
        <section class="rsc-card rsc-reward-summary"><h2>{{uiText
              "today_reward"
            }}
            ·
            {{this.data.reward.date}}</h2><div class="rsc-market-summary"><div
            ><span>{{uiText "reward_login"}}</span><strong
              >{{this.data.reward.login}} / 1</strong></div><div><span>{{uiText
                  "reward_topics"
                }}</span><strong>{{this.data.reward.topics}}</strong></div><div><span>{{uiText "reward_replies"}}</span><strong>{{this.data.reward.replies}}</strong></div><div
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
        <section class="rsc-card"><h2>{{uiText "history"}}</h2><div
            class="rsc-scroll"
          ><table><thead><tr><th>{{uiText "time"}}</th><th>{{uiText
                      "operation"
                    }}</th><th>{{uiText "amount"}}</th><th>{{uiText
                      "balance"
                    }}</th></tr></thead><tbody>{{#each
                  this.data.entries
                  as |entry|
                }}<tr><td>{{when entry.created_at}}</td><td>{{uiText
                        entry.operation
                      }}</td><td>{{formatAmount entry.amount}}</td><td
                    >{{formatAmount entry.balance}}</td></tr>{{else}}<tr><td
                      colspan="4"
                    >{{uiText
                        "empty"
                      }}</td></tr>{{/each}}</tbody></table></div></section>
        <RscLedger @journalId={{this.args.model.focus.journal_id}} />
      {{else if (eq @section "market")}}
        <div
          class="rsc-market-summary"
          aria-label={{uiText "account_overview"}}
        >
          <div><span>{{uiText "margin"}}</span><strong
            >{{formatAmount this.data.portfolio.margin}} <small>RSC</small></strong></div>
          <div><span>{{uiText "portfolio_equity"}}</span><strong>{{pretty
                this.data.portfolio.equity
              }}
              <small>RSC</small></strong></div>
          <div><span>{{uiText "pnl"}}</span><strong
              class={{tone this.data.portfolio.pnl}}
            >{{pretty this.data.portfolio.pnl}}
              <small>RSC</small></strong></div>
          <div><span>{{uiText "my_positions"}}</span><strong
            >{{this.data.positions.length}}
              <small>{{uiText "positions_count"}}</small></strong></div>
        </div>
        <div class="rsc-market-jumps"><a href="#rsc-positions">{{uiText
              "positions"
            }}
            <span>{{this.data.positions.length}}</span></a><a
            href="#rsc-orders"
          >{{uiText "orders"}}
            <span>{{this.data.orders.length}}</span></a></div>
        <div class="rsc-workbench {{if this.marketDetailOpen 'detail-open'}}">
          <RscMarketList
            @instruments={{this.data.instruments}}
            @now={{this.quoteClock}}
            @selectedId={{this.selected.id}}
            @onSelect={{this.selectMarket}}
            @onTrade={{this.quickTrade}}
            @readOnly={{this.data.read_only}}
          />
          {{#if this.selected}}
            <div class="rsc-market-layout"><section class="rsc-card rsc-chart">
                <button
                  type="button"
                  class="rsc-back"
                  {{on "click" this.backToMarkets}}
                >← {{uiText "back_to_markets"}}</button>
                <div class="rsc-detail-heading"><div><p
                      class="rsc-eyebrow"
                    >{{this.selected.symbol}}</p><h2
                    >{{this.selected.name}}</h2></div><span
                    class="rsc-market-status {{this.selectedMarket.status}}"
                  >{{uiText this.selectedMarket.status}}</span></div>
                <div class="rsc-quote-hero"><strong
                    class="rsc-price"
                  >{{formatPrice this.selected.quote.price}}
                    <small>RSC</small></strong><span
                    class="rsc-change-pill {{this.selectedMarket.tone}}"
                  >{{this.selectedMarket.changeText}}</span></div>
                <p class="rsc-muted">{{uiText "daily_change"}}
                  ·
                  {{uiText "previous_close_basis"}}</p>
                {{#each
                  (array this.selected) key="id"
                  as |instrument|
                }}<RscHistory @instrument={{instrument}} />{{/each}}<p
                  class="rsc-muted"
                >{{uiText "quote_time"}}
                  {{when this.selected.quote.source_time}}
                  ·
                  {{uiText "auto_refresh"}}</p></section>
              <section class="rsc-card rsc-order-ticket"><div
                  class="rsc-ticket-heading"
                ><h2>{{uiText "order"}}</h2><span
                  >{{this.selected.symbol}}</span></div><form
                  {{on "submit" this.trade}}
                ><label>{{uiText "direction"}}<select
                      {{on "change" (fn this.set "side")}}
                    ><option
                        value="long"
                        selected={{eq this.side "long"}}
                      >{{uiText "long"}}</option><option
                        value="short"
                        selected={{eq this.side "short"}}
                      >{{uiText "short"}}</option></select></label><div
                    class="rsc-fields"
                  ><label>{{uiText "quantity"}}<input
                        required
                        inputmode="decimal"
                        value={{this.quantity}}
                        {{on "input" (fn this.set "quantity")}}
                      /></label><label>{{uiText "leverage"}}<input
                        required
                        type="number"
                        min="1"
                        max={{this.maxLeverage}}
                        value={{this.leverage}}
                        {{on "input" (fn this.set "leverage")}}
                      /></label></div>{{#if this.data.high_risk_enabled}}{{#if
                      (eq this.selected.category "crypto")
                    }}<label class="rsc-checkbox"><input
                          type="checkbox"
                          checked={{this.highRisk}}
                          {{on "change" this.toggleHighRisk}}
                        />{{uiText "high_risk_mode"}}</label>{{/if}}{{/if}}<p
                    class="rsc-muted"
                  >{{#if (eq this.selected.execution_mode "immediate")}}实时股票按当前可用行情成交。{{else if (eq this.selected.execution_mode "crypto_confirmation")}}虚拟币开仓等待 30–90 秒报价确认，初始两分钟不可撤单；手动平仓须满足五分钟持仓时间。{{else}}延迟行情需等待后续报价确认；提交后 10 秒内可撤单，成交后至少持有两分钟。{{/if}}</p>
                  {{#if this.selected.close_only}}<p class="alert alert-info">此杠杆/反向产品目前仅可平仓。</p>{{/if}}
                  <p class="rsc-muted">最小数量 {{formatQuantity this.selected.minimum}} · 步进 {{formatQuantity this.selected.step}} · 价格与名义金额均以 RSC 计价</p>
                  {{#unless (eq this.side "close")}}<div class="rsc-fields"><label>{{uiText "take_profit"}}<input inputmode="decimal" value={{this.takeProfit}} {{on "input" (fn this.set "takeProfit")}} /></label><label>{{uiText "stop_loss"}}<input inputmode="decimal" value={{this.stopLoss}} {{on "input" (fn this.set "stopLoss")}} /></label></div>
                  {{#if this.estimate}}<div class="rsc-order-estimate"><p>预计名义金额 {{formatAmount this.estimate.gross}} RSC · 保证金 {{formatAmount this.estimate.margin}} RSC</p><p>手续费 {{formatAmount this.estimate.fee}} RSC · 预计占用 {{formatAmount this.estimate.reserve}} RSC</p><button type="button" class="btn btn-small" {{on "click" this.maximum}}>按余额填入数量上限 {{formatQuantity this.estimate.maximum}}</button><small>估算不包含其他持仓的风控额度，成交仍须通过服务端检查。</small></div>{{/if}}{{/unless}}<button
                    class="btn btn-primary"
                    type="submit"
                    disabled={{this.tradingDisabled}}
                  >{{uiText "submit_order"}}</button></form></section></div>
          {{else}}<p class="rsc-empty">{{uiText "no_quotes"}}</p>{{/if}}
        </div>
        <RscDiscovery />
        <section id="rsc-positions" class="rsc-card"><h2>{{uiText
              "positions"
            }}</h2>{{#each this.positions as |position|}}<article
              class="rsc-position"
            ><div class="rsc-position-overview"><div
                  class="rsc-position-title"
                ><strong>{{position.symbol}}</strong><span
                    class="rsc-direction"
                    data-side={{position.side}}
                  >{{uiText position.side}}
                    {{position.leverage}}×</span>{{#unless
                    (eq position.valuation_basis "current")
                  }}<small
                      class="rsc-valuation-note"
                      title={{when position.valuation_at}}
                    >{{uiText
                        position.valuation_basis
                      }}</small>{{/unless}}</div>
                <dl class="rsc-position-metrics"><div><dt>{{uiText
                        "quantity"
                      }}</dt><dd>{{formatQuantity
                        position.quantity
                      }}</dd></div><div><dt>{{uiText "margin"}}</dt><dd
                    >{{formatAmount position.margin}}</dd></div><div><dt
                    >{{uiText "pnl"}}</dt><dd
                      class={{tone position.pnl}}
                    >{{pretty position.pnl}}</dd></div><div><dt>{{uiText
                        "liquidation_price"
                      }}</dt><dd
                    >{{formatPrice position.liquidation}}</dd></div></dl><dl class="rsc-position-metrics"><div><dt>持仓均价</dt><dd>{{formatPrice position.average}}</dd></div><div><dt>单仓权益</dt><dd>{{formatAmount position.equity}}</dd></div><div><dt>保本价</dt><dd>{{formatPrice position.break_even}}</dd></div><div><dt>维持保证金</dt><dd>{{formatAmount position.maintenance}}</dd></div><div><dt>风险状态</dt><dd>{{#if (eq position.risk "normal")}}正常{{else if (eq position.risk "high")}}较高{{else if position.risk}}已达强平线{{else}}报价不足{{/if}}</dd></div></dl>{{#if position.remaining}}<p>距离可手动平仓约 {{position.remaining}} 秒（{{when position.hold_until}}）</p>{{/if}}</div><form class="rsc-partial-close" {{on "submit" (fn this.close position)}}><label>平仓数量<input required inputmode="decimal" value={{position.closeQuantity}} {{on "input" (fn this.closeQuantity position.id)}} /></label><button class="btn" type="submit" disabled={{position.closeDisabled}}>{{uiText "close_position"}}</button></form><form
                class="rsc-protection"
                {{on "submit" (fn this.protect position)}}
              ><label>{{uiText "take_profit"}}<input
                    inputmode="decimal"
                    value={{position.tp}}
                    {{on "input" (fn this.protection position.id "tp")}}
                  /></label><label>{{uiText "stop_loss"}}<input
                    inputmode="decimal"
                    value={{position.sl}}
                    {{on "input" (fn this.protection position.id "sl")}}
                  /></label><button
                  class="btn"
                  type="submit"
                  disabled={{this.writeDisabled}}
                >{{uiText "save"}}</button></form><form
                class="rsc-protection"
                {{on "submit" (fn this.addMargin position)}}
              ><label>{{uiText "add_margin"}}<input
                    required
                    inputmode="decimal"
                    {{on "input" (fn this.marginDraft position.id)}}
                  /></label><button
                  class="btn"
                  type="submit"
                  disabled={{this.writeDisabled}}
                >{{uiText "add_margin"}}</button></form></article>{{else}}<p
              class="rsc-muted"
            >{{uiText "no_positions"}}</p>{{/each}}</section>
        <p class="rsc-muted">持仓名义金额 {{formatAmount this.data.portfolio.notional}} RSC · 委托占用 {{formatAmount this.data.portfolio.reserved}} RSC</p>
        <section id="rsc-orders" class="rsc-card"><h2>{{uiText
              "orders"
            }}</h2><div class="rsc-scroll"><table><thead><tr><th>{{uiText
                      "time"
                    }}</th><th>{{uiText "instrument"}}</th><th>{{uiText
                      "direction"
                    }}</th><th>{{uiText "quantity"}}</th><th>{{uiText
                      "status"
                    }}</th><th></th></tr></thead><tbody>{{#each
                  this.data.orders
                  as |order|
                }}<tr id="rsc-order-{{order.id}}"><td>{{when order.created_at}}</td><td
                    >{{order.symbol}}</td><td>{{uiText order.side}}
                      {{order.leverage}}×</td><td>{{formatQuantity
                        order.quantity
                      }}</td><td>{{uiText order.status}}{{#if order.details.reason}} · {{uiText order.details.reason}}{{/if}}
                    {{#if order.details.price}}<div>成交 {{formatPrice order.details.price}} · 手续费 {{formatAmount order.details.fee}} RSC</div>{{/if}}
                    {{#if order.details.gross}}<div>名义金额 {{formatAmount order.details.gross}} RSC</div>{{/if}}
                    {{#if order.details.pnl}}<div>盈亏 {{formatAmount order.details.pnl}} · 返还 {{formatAmount order.details.payout}} RSC</div>{{/if}}
                    {{#if order.details.error}}<div>{{order.error_message}}</div>{{/if}}
                    {{#if (eq order.status "pending")}}<div>预占 {{formatAmount order.reserved}} RSC · 最早处理 {{when order.execute_at}}</div><small>{{#if order.cancel_at}}可撤单时间 {{when order.cancel_at}}{{else}}撤单截止 {{when order.cancel_until}}{{/if}} · 到期 {{when order.expires_at}}</small>{{/if}}</td><td>{{#if
                        (eq order.status "pending")
                      }}<button
                          class="btn btn-small"
                          type="button"
                          disabled={{if this.busy true (not order.can_cancel)}}
                          {{on "click" (fn this.cancel order)}}
                        >{{uiText
                            "cancel"
                          }}</button>{{/if}}</td></tr>{{else}}<tr><td
                      colspan="6"
                    >{{uiText
                        "empty"
                      }}</td></tr>{{/each}}</tbody></table></div></section>
      {{else if (eq @section "sports")}}
        <div class="rsc-fields"><label>项目<select {{on "change" (fn this.set "sport")}}><option value="all">全部项目</option><option value="soccer">足球</option><option value="basketball">篮球</option></select></label><label>赛事筛选<select {{on "change" (fn this.set "matchFilter")}}><option value="open">可预测</option><option value="popular">热门</option><option value="closed">已截止</option><option value="unavailable">未开放</option><option value="mine">我的预测</option><option value="all">全部</option></select></label></div>
        <label class="rsc-league-filter">{{uiText "league"}}<select
            {{on "change" (fn this.set "league")}}
          ><option value="all">{{uiText "category_all"}}</option>{{#each
              this.leagues
              as |league|
            }}<option
                value={{league.id}}
              >{{league.label}}</option>{{/each}}</select></label>
        <div class="rsc-grid">{{#each this.matches as |match|}}<article
              class="rsc-card rsc-match" id="rsc-match-{{match.id}}"
            ><div class="rsc-match-meta"><span
                  class="rsc-eyebrow"
                >{{match.league_name}}</span><span
                  class="rsc-state-pill"
                  data-status={{match.status}}
                >{{uiText match.status}}</span></div>
              {{#if match.stage}}<p class="rsc-muted">{{match.stage}}</p>{{/if}}
              <h2 class="rsc-teams"><span class="rsc-team"><span
                    class="rsc-team-symbol"
                    aria-hidden="true"
                  >{{initials match.home}}</span><span
                  >{{match.home}}</span></span><span
                  class="rsc-versus"
                >VS</span><span class="rsc-team"><span
                    class="rsc-team-symbol away"
                    aria-hidden="true"
                  >{{initials match.away}}</span><span
                  >{{match.away}}</span></span></h2>
              <p class="rsc-match-time">{{when match.starts_at}} · {{match.participants}} 人参与</p>
              {{#if match.venue}}<p class="rsc-muted">{{match.venue}}</p>{{/if}}
              {{#if match.status_detail}}<p class="rsc-muted">{{match.status_detail}}</p>{{/if}}
              <p>比分 {{match.score.home}} : {{match.score.away}}</p><p class="rsc-muted">赔率更新 {{when match.odds_at}}{{#if match.locked_reason}} · {{#if (eq match.locked_reason "odds_unavailable")}}赔率暂不可用{{else}}赛事已封盘{{/if}}{{/if}}</p><form
                {{on "submit" (fn this.predict match)}}
              ><div class="rsc-odds">{{#each match.choices as |choice|}}<label
                      class={{if
                        (eq choice.pick match.draftPick)
                        "selected"
                        ""
                      }}
                    ><input
                        type="radio"
                        name={{match.id}}
                        value={{choice.pick}}
                        checked={{eq choice.pick match.draftPick}}
                        disabled={{match.locked}}
                        {{on "change" (fn this.draft match.id "pick")}}
                      /><span>{{choice.title}}</span><strong
                      >{{choice.odds}}</strong></label>{{/each}}</div><label
                >{{uiText "stake"}}<input
                    required
                    inputmode="decimal"
                    value={{match.draftStake}}
                    disabled={{match.locked}}
                    {{on "input" (fn this.draft match.id "stake")}}
                  /></label><button
                  class="btn btn-primary"
                  type="submit"
                  disabled={{if this.busy true match.locked}}
                >{{#if match.locked}}{{uiText "locked"}}{{else if
                    match.prediction
                  }}{{uiText "update_prediction"}}{{else}}{{uiText
                      "predict"
                    }}{{/if}}</button><p class="rsc-muted">预计返还 {{formatAmount match.potentialPayout}} RSC（含本金）</p></form>{{#if match.prediction}}<p
                  class="rsc-prediction"
                >{{uiText "your_prediction"}}:
                  {{uiText match.prediction.pick}}
                  ·
                  {{formatAmount match.prediction.stake}}
                  RSC @
                  {{match.prediction.odds}}
                  ·
                  {{uiText
                    match.prediction.status
                  }} · 预计返还 {{formatAmount match.prediction.potential_payout}} RSC · 实际返还 {{formatAmount match.prediction.payout}} RSC</p>{{/if}}</article>{{else}}<p class="rsc-empty">{{uiText
                "no_matches"
              }}</p>{{/each}}</div>
        <section class="rsc-card"><h2>{{uiText "predictions"}}</h2><div
            class="rsc-scroll"
          ><table><thead><tr><th>{{uiText "match"}}</th><th>{{uiText
                      "pick"
                    }}</th><th>{{uiText "stake"}}</th><th>{{uiText
                      "odds"
                    }}</th><th>{{uiText "status"}}</th><th>{{uiText
                      "payout"
                    }}</th></tr></thead><tbody>{{#each
                  this.data.predictions
                  as |prediction|
                }}<tr><td>{{prediction.match_name}}</td><td>{{uiText
                        prediction.pick
                      }}</td><td>{{formatAmount prediction.stake}}</td><td
                    >{{prediction.odds}}</td><td>{{uiText
                        prediction.status
                      }}</td><td>{{formatAmount
                        prediction.payout
                      }}</td></tr>{{else}}<tr><td colspan="6">{{uiText
                        "empty"
                      }}</td></tr>{{/each}}</tbody></table></div></section>
      {{else if (eq @section "packet")}}
        <section class="rsc-card rsc-packet"><p>{{this.data.packet.sender}}
            ·
            {{uiText "packet"}}</p><h2>{{this.data.packet.message}}</h2><strong
            class="rsc-price"
          >{{formatAmount this.data.packet.total}} RSC</strong>
          {{#if this.data.packet.my_amount}}<p class="rsc-price">你已领取 {{formatAmount this.data.packet.my_amount}} RSC</p>{{/if}}
          <p>剩余金额 {{formatAmount this.data.packet.remaining}} RSC{{#if this.data.packet.minimum}} · 每份 {{formatAmount this.data.packet.minimum}} – {{formatAmount this.data.packet.maximum}} RSC{{/if}}</p><button type="button" class="btn" {{on "click" this.copyPacket}}>复制红包链接</button><p
          >{{this.data.packet.claimed_count}}
            /
            {{this.data.packet.count}}
            ·
            {{uiText this.data.packet.status}}</p>{{#if
            (eq this.data.packet.status "open")
          }}{{#if this.data.packet.own}}<button
                class="btn"
                type="button"
                disabled={{this.writeDisabled}}
                {{on "click" this.closePacket}}
              >{{uiText "close_packet"}}</button><p class="rsc-muted">{{uiText
                  "share_packet"
                }}</p>{{else if this.data.packet.claimed}}<p>{{uiText
                  "already_claimed"
                }}</p>{{else}}<button
                class="btn btn-primary"
                type="button"
                disabled={{this.writeDisabled}}
                {{on "click" this.claim}}
              >{{uiText "claim_packet"}}</button>{{/if}}{{/if}}<p>{{uiText
              "expires_at"
            }}
            {{when this.data.packet.expires_at}}</p></section>
        <section class="rsc-card"><h2>{{uiText "packet_claims"}}</h2><div
            class="rsc-table"
          ><table><tbody>{{#each this.data.packet.claims as |claim|}}<tr><td
                    >{{claim.username}}</td><td>{{formatAmount claim.amount}}
                      RSC</td><td>{{when claim.at}}</td></tr>{{else}}<tr><td
                    >{{uiText
                        "empty"
                      }}</td></tr>{{/each}}</tbody></table></div></section>
      {{/if}}
    </main>
  </template>
}
