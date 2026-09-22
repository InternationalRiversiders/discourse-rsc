import { formatDateTime } from "../lib/campus-time";
import RscNavigation from "./rsc-navigation";
import ForumUser from "./rsc-user";
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
import RscOrders from "./rsc-orders";
import RscTeam from "./rsc-team";
import RscHistory from "./rsc-history";
import RscDiscovery from "./rsc-discovery";
import RscMarketList from "./rsc-market-list";
import {
  formatAmount,
  formatWallet,
  formatQuantity,
  formatPrice,
  signedAmount,
} from "../lib/rsc-format";
import { estimate, payout, quantityForFraction, atomic } from "../lib/rsc-estimate";
import { marketView } from "../lib/rsc-market";
import { i18n } from "discourse-i18n";

const uiText = (value) => i18n(`discourse_rsc.ui.${value}`);
const pretty = formatAmount;
const displayAmount = formatWallet;
const tone = (value) =>
  Number(value) > 0 ? "positive" : Number(value) < 0 ? "negative" : "neutral";
const when = formatDateTime;
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
  clockTimer;
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
      this.highRisk = Number(this.leverage) > 10;
    }
    if (this.args.model.focus?.match_id) { this.matchFilter = "all"; }
    this.clockTimer = setInterval(() => {
      if (this.args.section === "market" && !document.hidden) { this.quoteClock = Date.now(); }
    }, 1000);
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
    clearInterval(this.clockTimer);
  }
  get data() {
    return this.snapshot || this.args.model;
  }
  get compactHeader() { return ["packet", "market"].includes(this.args.section); }
  get ledgerRevision() {
    return this.data.entries[0]?.id;
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
      this.busy || this.highRiskStatus.blocked ||
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
    this.highRisk = Number(this.leverage) > 10;
    this.takeProfit = ""; this.stopLoss = "";
    this.notice = "";
    this.error = "";
    requestAnimationFrame(() => {
      const panel = document.querySelector(".rsc-market-layout");
      panel?.scrollTo({ top: 0 });
      if (window.matchMedia("(max-width: 1099px)").matches) { panel?.scrollIntoView({ block: "start" }); }
    });
    Promise.resolve().then(() => {
      if (!this.isDestroying && !this.isDestroyed) {
        return this.refresh();
      }
    }).catch(() => {});
  }
  @action viewPosition(position) {
    this.selectMarket(position.instrument_id);
    requestAnimationFrame(() => document.querySelector(".rsc-market-layout")?.scrollIntoView({ block: "start", behavior: "smooth" }));
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
  @action allocate(quarters) {
    const quantity = quantityForFraction(this.selected, this.leverage, this.data.wallet.balance, quarters);
    if (quantity === null || atomic(quantity) < (atomic(this.selected?.minimum) || 1n)) {
      this.error = "该比例的余额不足以满足最小建仓数量。";
      return;
    }
    this.error = "";
    this.quantity = quantity;
  }
  get highRiskStatus() {
    const status = this.data.high_risk || {};
    const positions = status.positions || [], pending = status.pending || [];
    const occupying = [...new Set([...positions, ...pending].map(p => p.symbol))].join("、");
    const samePosition = positions.find(p => p.instrument_id === this.selected?.id);
    const elsewhere = [...positions, ...pending].some(p => p.instrument_id !== this.selected?.id);
    const seconds = status.cooldown_until ? Math.max(0, Math.ceil((Date.parse(status.cooldown_until) - this.quoteClock) / 1000)) : 0;
    const hold = samePosition?.hold_until ? Math.max(0, Math.ceil((Date.parse(samePosition.hold_until) - this.quoteClock) / 1000)) : 0;
    return { occupying, seconds, countdown: `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`, hold,
      blocked: Number(this.leverage) > 10 && (elsewhere || (!samePosition && seconds > 0)) };
  }
  get quoteStats() {
    const q = this.selected?.quote || {};
    return this.selected?.category === "crypto"
      ? [{ label: "24h 最高", value: q.high }, { label: "24h 最低", value: q.low }]
      : [{ label: "开盘", value: q.open }, { label: "前收", value: q.previous_close }, { label: "最高", value: q.high }, { label: "最低", value: q.low }];
  }
  get changeLabel() { return this.selectedMarket?.changeLabel; }
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
    requestAnimationFrame(() => document.querySelector("#rsc-markets")?.scrollIntoView({ block: "start" }));
  }
  @action showPositions(event) {
    event.preventDefault();
    this.marketDetailOpen = false;
    requestAnimationFrame(() => document.querySelector("#rsc-positions")?.scrollIntoView({ block: "start" }));
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
      marginDraft: this.margins[position.id] ?? "",
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
      {{#if (eq @section "packet")}}
        <nav class="rsc-packet-nav" aria-label="红包导航"><LinkTo @route="rsc.index">← RS Coin</LinkTo><span>{{uiText "available"}} {{displayAmount this.data.wallet.balance}} RSC</span></nav>
      {{else}}
        <RscNavigation />
      {{/if}}
      {{#if this.data.wallet.status_reason}}<p class="alert alert-info">账户已冻结：{{this.data.wallet.status_reason}}</p>{{/if}}
      <h1 class="sr-only">{{#if (eq @section "market")}}{{uiText "exchange_title"}}{{else if (eq @section "sports")}}{{uiText "sports"}}{{else}}{{uiText "title"}}{{/if}}</h1>
      {{#unless this.compactHeader}}<p class="rsc-wallet-balance">{{uiText "available"}} <strong title={{this.data.wallet.balance}}>{{displayAmount this.data.wallet.balance}} RSC</strong></p>{{/unless}}
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
        <RscLedger @journalId={{this.args.model.focus.journal_id}} @revision={{this.ledgerRevision}} />
      {{else if (eq @section "market")}}
        <div
          class="rsc-market-summary rsc-trading-summary"
          aria-label={{uiText "account_overview"}}
        >
          <div><span>{{uiText "available"}}</span><strong>{{displayAmount this.data.wallet.balance}} <small>RSC</small></strong></div>
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
        </div>
        <div class="rsc-market-jumps"><a href="#rsc-positions" {{on "click" this.showPositions}}>{{uiText
              "positions"
            }}
            <span>{{this.data.positions.length}}</span></a><a
            href="#rsc-orders"
          >{{uiText "orders"}}
            <span>{{this.data.orders.length}}</span></a></div>
        <div class="rsc-workbench {{if this.marketDetailOpen 'detail-open'}}">
          <div class="rsc-market-main">
        <section id="rsc-positions" class="rsc-card rsc-positions-card"><h2>{{uiText
              "positions"
            }}</h2>{{#each this.positions key="id" as |position|}}<article
              class="rsc-position"
            ><div class="rsc-position-overview"><div
                  class="rsc-position-title"
                ><button type="button" class="rsc-position-link" {{on "click" (fn this.viewPosition position)}}><strong>{{position.name}}</strong><small>{{position.symbol}}</small></button><span
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
                      }}</small>{{/unless}}{{#if (eq position.risk "high")}}<span class="negative">风险较高</span>{{else if (eq position.risk "liquidation")}}<span class="negative">已达强平线</span>{{/if}}</div>
                <dl class="rsc-position-metrics"><div><dt>数量</dt><dd>{{formatQuantity position.quantity}}</dd></div><div><dt>均价</dt><dd>{{formatPrice position.average}}</dd></div><div><dt>保证金</dt><dd>{{formatAmount position.margin}}</dd></div><div><dt>浮动盈亏</dt><dd class={{tone position.pnl}}>{{signedAmount position.pnl}}</dd></div></dl>{{#if position.remaining}}<p>距离可手动平仓约 {{position.remaining}} 秒（{{when position.hold_until}}）</p>{{/if}}</div><details class="rsc-position-details"><summary>管理持仓 · 平仓 / 止盈止损</summary><dl class="rsc-position-metrics"><div><dt>强平价</dt><dd>{{formatPrice position.liquidation}}</dd></div><div><dt>单仓权益</dt><dd>{{formatAmount position.equity}}</dd></div><div><dt>保本价</dt><dd>{{formatPrice position.break_even}}</dd></div><div><dt>维持保证金</dt><dd>{{formatAmount position.maintenance}}</dd></div></dl><p class="rsc-muted">风险状态：{{#if (eq position.risk "normal")}}正常{{else if (eq position.risk "high")}}较高{{else if position.risk}}已达强平线{{else}}报价不足{{/if}} · 金额单位 RSC</p><form class="rsc-partial-close" {{on "submit" (fn this.close position)}}><label>平仓数量<input required inputmode="decimal" value={{position.closeQuantity}} {{on "input" (fn this.closeQuantity position.id)}} /></label><button class="btn" type="submit" disabled={{position.closeDisabled}}>{{uiText "close_position"}}</button></form><form
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
                    value={{position.marginDraft}}
                    {{on "input" (fn this.marginDraft position.id)}}
                  /></label><button
                  class="btn"
                  type="submit"
                  disabled={{this.writeDisabled}}
                >{{uiText "add_margin"}}</button></form></details></article>{{else}}<p
              class="rsc-muted"
            >{{uiText "no_positions"}}</p>{{/each}}</section>
          <RscMarketList
            @instruments={{this.data.instruments}}
            @now={{this.quoteClock}}
            @selectedId={{this.selected.id}}
            @onSelect={{this.selectMarket}}
            @onTrade={{this.quickTrade}}
            @readOnly={{this.data.read_only}}
          /></div>
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
                <p class="rsc-muted rsc-change-basis">{{this.changeLabel}} · 价格单位 RSC</p>
                <dl class="rsc-quote-stats">{{#each this.quoteStats key="label" as |stat|}}<div><dt>{{stat.label}}</dt><dd title={{stat.value}}>{{formatPrice stat.value}}</dd></div>{{/each}}</dl>
                {{#each
                  (array this.selected) key="id"
                  as |instrument|
                }}<RscHistory @instrument={{instrument}} />{{/each}}<p
                  class="rsc-muted"
                >{{uiText "quote_time"}}
                  {{when this.selected.quote.source_time}}
                  ·
                  {{uiText "auto_refresh"}}</p></section>
              <section class="rsc-card rsc-order-ticket">
                <div class="rsc-ticket-heading"><h2>{{uiText "order"}}</h2><span>{{this.selected.symbol}}</span></div>
                <form {{on "submit" this.trade}}>
                  <label>{{uiText "direction"}}<select {{on "change" (fn this.set "side")}}><option value="long" selected={{eq this.side "long"}}>{{uiText "long"}}</option><option value="short" selected={{eq this.side "short"}}>{{uiText "short"}}</option></select></label>
                  <div class="rsc-fields rsc-ticket-inputs">
                    <div><label>{{uiText "quantity"}}<input required inputmode="decimal" value={{this.quantity}} {{on "input" (fn this.set "quantity")}} /></label>
                      <span class="rsc-allocation-buttons">{{#each (array 1 2 3 4) as |quarter|}}<button type="button" class="btn btn-small" {{on "click" (fn this.allocate quarter)}}>{{#if (eq quarter 4)}}全仓{{else if (eq quarter 2)}}1/2{{else}}{{quarter}}/4{{/if}}</button>{{/each}}</span>
                    </div>
                    <div><label>{{uiText "leverage"}} <output>{{this.leverage}}×</output><input class="rsc-leverage-range" aria-label="杠杆滑块" type="range" min="1" max={{this.maxLeverage}} step="1" value={{this.leverage}} {{on "input" (fn this.set "leverage")}} /></label><input aria-label="杠杆倍数" required type="number" min="1" max={{this.maxLeverage}} step="1" value={{this.leverage}} {{on "input" (fn this.set "leverage")}} /></div>
                  </div>
                  {{#if this.data.high_risk_enabled}}{{#if (eq this.selected.category "crypto")}}
                    <label class="rsc-checkbox"><input type="checkbox" checked={{this.highRisk}} {{on "change" this.toggleHighRisk}} />{{uiText "high_risk_mode"}}</label>
                    <div class="rsc-risk-status"><strong>高杠杆（11–100×）</strong><span>{{#if this.highRiskStatus.occupying}}占用中：{{this.highRiskStatus.occupying}}{{else}}名额空闲{{/if}}</span>{{#if this.highRiskStatus.seconds}}<span>冷却倒计时 <b>{{this.highRiskStatus.countdown}}</b>（现有同标的高杠杆仓位可继续加仓）</span>{{else}}<span>当前无冷却</span>{{/if}}{{#if this.highRiskStatus.hold}}<span>当前仓位还需 {{this.highRiskStatus.hold}} 秒可手动平仓</span>{{/if}}</div>
                  {{/if}}{{/if}}
                  {{#if this.selected.close_only}}<p class="alert alert-info">此杠杆/反向产品目前仅可平仓。</p>{{/if}}
                  <div class="rsc-fields"><label>{{uiText "take_profit"}}<input inputmode="decimal" value={{this.takeProfit}} {{on "input" (fn this.set "takeProfit")}} /></label><label>{{uiText "stop_loss"}}<input inputmode="decimal" value={{this.stopLoss}} {{on "input" (fn this.set "stopLoss")}} /></label></div>
                  {{#if this.estimate}}<div class="rsc-order-estimate"><p>名义金额 {{formatAmount this.estimate.gross}} · 保证金 {{formatAmount this.estimate.margin}}</p><p>手续费 {{formatAmount this.estimate.fee}} · 预计占用 {{formatAmount this.estimate.reserve}} RSC</p><small>可用余额上限 {{formatQuantity this.estimate.maximum}} · 成交仍须通过风控检查。</small></div>{{/if}}
                  <button class="btn btn-primary" type="submit" disabled={{this.tradingDisabled}}>{{uiText "submit_order"}}</button>
                  <details class="rsc-trading-help"><summary>交易规则 · 数量步进 {{formatQuantity this.selected.step}}</summary><p class="rsc-muted">{{#if (eq this.selected.execution_mode "immediate")}}按当前可用行情成交。{{else if (eq this.selected.execution_mode "crypto_confirmation")}}开仓等待 30–90 秒报价确认，初始两分钟不可撤单；手动平仓至少持有五分钟。{{else}}等待后续报价确认；提交后 10 秒内可撤单，成交后至少持有两分钟。{{/if}}</p><p class="rsc-muted">最小数量 {{formatQuantity this.selected.minimum}}。四档比例按可用余额估算，包含手续费及预占空间；仍受单仓和组合限额约束。</p></details>
                </form>
              </section>
</div>
          {{else}}<p class="rsc-empty">{{uiText "no_quotes"}}</p>{{/if}}
        </div>
        <RscDiscovery />
        <p class="rsc-muted">持仓名义金额 {{formatAmount this.data.portfolio.notional}} RSC · 委托占用 {{formatAmount this.data.portfolio.reserved}} RSC</p>
        <RscOrders @orders={{this.data.orders}} @busy={{this.busy}} @cancel={{this.cancel}} />
      {{else if (eq @section "sports")}}
        <div class="rsc-filter-bar rsc-sports-filters"><label>项目<select {{on "change" (fn this.set "sport")}}><option value="all">全部项目</option><option value="soccer">足球</option><option value="basketball">篮球</option></select></label><label>赛事筛选<select {{on "change" (fn this.set "matchFilter")}}><option value="open">可预测</option><option value="popular">热门</option><option value="closed">已截止</option><option value="unavailable">未开放</option><option value="mine">我的预测</option><option value="all">全部</option></select></label>
        <label>{{uiText "league"}}<select
            {{on "change" (fn this.set "league")}}
          ><option value="all">{{uiText "category_all"}}</option>{{#each
              this.leagues
              as |league|
            }}<option
                value={{league.id}}
              >{{league.label}}</option>{{/each}}</select></label></div>
        <div class="rsc-grid">{{#each this.matches key="id" as |match|}}<article
              class="rsc-card rsc-match" id="rsc-match-{{match.id}}"
            ><div class="rsc-match-meta"><span
                  class="rsc-eyebrow"
                >{{match.league_name}}</span><span
                  class="rsc-state-pill"
                  data-status={{match.status}}
                >{{uiText match.status}}</span></div>
              {{#if match.stage}}<p class="rsc-muted">{{match.stage}}</p>{{/if}}
              <h2 class="rsc-teams"><RscTeam @name={{match.home_name}} @original={{match.home}} @logo={{match.home_logo}} /><span
                  class="rsc-versus"
                >VS</span><RscTeam @name={{match.away_name}} @original={{match.away}} @logo={{match.away_logo}} @away={{true}} /></h2>
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
        <section class="rsc-card rsc-packet"><p><ForumUser @user={{this.data.packet.sender_user}} @name={{this.data.packet.sender}} />
            ·
            {{uiText "packet"}}</p><h1>{{this.data.packet.message}}</h1><strong
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
            <time datetime={{this.data.packet.expires_at}}>{{when this.data.packet.expires_at}}</time></p></section>
        <section class="rsc-card"><h2>{{uiText "packet_claims"}}</h2><div
            class="rsc-table"
          ><table><tbody>{{#each this.data.packet.claims as |claim|}}<tr><td
                    ><ForumUser @user={{claim.forum_user}} @name={{claim.username}} /></td><td>{{formatAmount claim.amount}}
                      RSC</td><td><time datetime={{claim.at}}>{{when claim.at}}</time></td></tr>{{else}}<tr><td
                    >{{uiText
                        "empty"
                      }}</td></tr>{{/each}}</tbody></table></div></section>
      {{/if}}
    </main>
  </template>
}
