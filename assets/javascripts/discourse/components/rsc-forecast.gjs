import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn, hash } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { LinkTo } from "@ember/routing";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { eq, gt } from "discourse/truth-helpers";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import { formatDateTime } from "../lib/campus-time";
import { formatAmount, signedAmount, valueTone } from "../lib/rsc-format";
import RscNavigation from "./rsc-navigation";

const ft = (key) => i18n(`discourse_rsc.forecast_ui.${key}`);
const categoryLabel = (key) => ft(`category_${key || "other"}`);
const pretty = formatAmount;
const signed = signedAmount;
const when = formatDateTime;
const outcomeLabel = (value) => value === "Yes" ? ft("yes") : value === "No" ? ft("no") : value;
const requestStatus = (value) => ft(`request_${value || "available"}`);
const status = (value) => ft(`state_${value}`);
const percent = (value) => `${(Number(value) * 100).toFixed(1).replace(/\.0$/, "")}%`;
const options = (market) => market.outcomes.map((name, index) => ({ name: outcomeLabel(name), index, probability: percent(market.prices[index]) }));
const tone = (value) => `forecast-${valueTone(value)}`;

export default class RscForecast extends Component {
  @tracked data;
  @tracked detail;
  @tracked section = "popular";
  @tracked showOriginal = false;
  @tracked search = "";
  @tracked category = "all";
  @tracked catalog = { markets: [], total: 0, page: 1, pages: 1, categories: {} };
  @tracked catalogQuery = "";
  @tracked catalogCategory = "all";
  @tracked catalogOrder = "balanced";
  @tracked catalogEvent = "";
  @tracked requestData = { mine: [], pending: [] };
  @tracked requestReason = "";
  @tracked previewReturnSection = "browse";
  @tracked reviewReasons = {};
  @tracked catalogLoading = false;
  catalogVersion = 0;
  @tracked outcome = 0;
  @tracked side = "buy";
  @tracked amount = "10";
  @tracked interval = "1w";
  @tracked history = [];
  @tracked chartLoading = false;
  @tracked chartError = "";
  @tracked error = "";
  @tracked notice = "";
  @tracked busy = false;
  @tracked quote = null;
  @tracked seconds = 0;
  historyVersion = 0;
  requestId = null;
  timer = null;

  constructor() {
    super(...arguments);
    // The route template keys this component by the complete model object.
    this.data = this.args.model;
    this.detail = this.args.model.detail;
    if (["browse", "joined", "requests", "review"].includes(this.args.model.initialSection)) {
      this.setSection(this.args.model.initialSection);
    }
    this.outcome = this.args.model.initialOutcome || 0;
    if (this.detail) { this.loadHistory(); }
  }

  willDestroy() {
    super.willDestroy(...arguments);
    this.historyVersion++;
    this.catalogVersion++;
    clearInterval(this.timer);
  }

  get markets() {
    const query = this.search.trim().toLowerCase();
    return this.data.markets.filter((m) => (this.category === "all" || (m.category || "other") === this.category) && (!query || `${m.question} ${m.event_title} ${m.original_question || ""}`.toLowerCase().includes(query)));
  }

  get categories() {
    return ["all", "technology", "culture", "economy", "crypto", "gaming", "sports", "world", "other"].map((key) => ({
      key, label: categoryLabel(key), count: this.data.markets.filter((m) => key === "all" || (m.category || "other") === key).length,
    })).filter((item) => item.count > 0 || item.key === "all");
  }

  @action
  setCategory(key) { this.category = key; }

  get catalogCategories() {
    return ["all", "technology", "culture", "economy", "crypto", "gaming", "sports", "world", "other"].map((key) => ({key, label: categoryLabel(key)}));
  }
  get previousDisabled() { return this.catalogLoading || this.catalog.page <= 1; }
  get nextDisabled() { return this.catalogLoading || this.catalog.page >= this.catalog.pages; }
  get reviewDisabled() { return this.busy || this.data.read_only; }
  get requestDisabled() { return this.busy || this.data.read_only || this.detail?.request_status === "pending" || !this.requestReason.trim(); }
  get pendingRequests() { return (this.requestData.pending || []).map((r) => ({...r, reviewReason: this.reviewReasons[r.external_id] || ""})); }

  get choices() { return this.detail ? options(this.detail) : []; }
  get selectedLabel() { return this.detail ? outcomeLabel(this.detail.outcomes[this.outcome]) : ""; }
  get selectedProbability() { return this.detail ? percent(this.detail.prices[this.outcome]) : ""; }
  get tradeDisabled() { return this.busy || this.data.read_only || this.detail?.state !== "open" || new Date(this.detail?.ends_at) <= new Date(); }
  get confirmationDisabled() { return this.tradeDisabled || this.seconds <= 0; }
  get currentHolding() {
    return this.data.holdings.find((p) => p.market_id === this.detail?.id && p.outcome === this.outcome && p.state === "open");
  }

  get points() {
    if (this.history.length < 2) { return ""; }
    const start = this.history[0].t;
    const span = Math.max(this.history.at(-1).t - start, 1);
    return this.history.map((p) => `${30 + (p.t - start) / span * 560},${180 - Number(p.p) * 160}`).join(" ");
  }

  get historyStart() { return this.history[0] ? when(new Date(this.history[0].t * 1000).toISOString()) : ""; }
  get historyEnd() { return this.history.at(-1) ? when(new Date(this.history.at(-1).t * 1000).toISOString()) : ""; }
  get result() {
    const values = this.detail?.payouts;
    if (!values) { return ""; }
    const sum = values.reduce((a, b) => a + b, 0);
    return values.map((p, index) => `${outcomeLabel(this.detail.outcomes[index])} ${pretty((p / sum).toFixed(6))} RSC`).join(" · ");
  }

  get detailQuestion() { return this.showOriginal ? this.detail.original_question : this.detail.question; }
  get detailRules() { return this.showOriginal ? this.detail.original_rules : this.detail.rules; }

  @action
  toggleOriginal() { this.showOriginal = !this.showOriginal; }

  @action
  setSection(value) {
    this.section = value; this.error = "";
    if (this.detail?.preview) { this.detail = null; }
    if (value === "browse") { this.loadCatalog(1); }
    if (["requests", "review"].includes(value)) { this.loadRequests(); }
  }

  async loadCatalog(page = 1) {
    const version = ++this.catalogVersion;
    this.catalogLoading = true; this.error = "";
    try {
      const data = await ajax("/rsc/forecast/catalog.json", { data: {q: this.catalogQuery, category: this.catalogCategory, order: this.catalogOrder, event_id: this.catalogEvent, page} });
      if (!this.isDestroying && version === this.catalogVersion) { this.catalog = data; }
    } catch (error) { if (!this.isDestroying && version === this.catalogVersion) { this.error = extractError(error); } }
    finally { if (!this.isDestroying && version === this.catalogVersion) { this.catalogLoading = false; } }
  }

  @action
  setCatalogQuery(event) { this.catalogQuery = event.target.value; }
  @action
  setCatalogCategory(event) { this.catalogCategory = event.target.value; this.catalogEvent = ""; this.loadCatalog(1); }
  @action
  setCatalogOrder(event) { this.catalogOrder = event.target.value; this.loadCatalog(1); }
  @action
  searchCatalog(event) { event.preventDefault(); this.catalogEvent = ""; this.loadCatalog(1); }
  @action
  browseEvent(id) { this.catalogEvent = id; this.loadCatalog(1); }
  @action
  pageCatalog(delta) { this.loadCatalog(this.catalog.page + delta); }
  @action
  closePreview() { this.detail = null; this.section = this.previewReturnSection; this.error = ""; }

  @action
  async previewCatalog(externalId) {
    this.previewReturnSection = ["requests", "review"].includes(this.section) ? this.section : "browse";
    this.busy = true; this.error = "";
    try {
      const detail = await ajax(`/rsc/forecast/catalog/${encodeURIComponent(externalId)}.json`);
      if (!this.isDestroying) { this.detail = detail; this.section = "popular"; this.requestReason = ""; this.showOriginal = false; this.clearQuote(); }
    } catch (error) { if (!this.isDestroying) { this.error = extractError(error); } }
    finally { if (!this.isDestroying) { this.busy = false; } }
  }
  @action
  setRequestReason(event) { this.requestReason = event.target.value; }
  @action
  async submitListing(event) {
    event.preventDefault(); if (this.requestDisabled) { return; }
    this.busy = true; this.error = "";
    try {
      const result = await ajax("/rsc/forecast/requests.json", {type: "POST", data: {external_id: this.detail.external_id, reason: this.requestReason, request_id: crypto.randomUUID()}});
      if (!this.isDestroying) { this.detail = {...this.detail, request_status: result.status, market_id: result.market_id}; this.notice = ft("request_sent"); }
    } catch (error) { if (!this.isDestroying) { this.error = extractError(error); } }
    finally { if (!this.isDestroying) { this.busy = false; } }
  }
  async loadRequests() {
    this.busy = true; this.error = "";
    try {
      const data = await ajax("/rsc/forecast/requests.json", {data: {admin: this.section === "review"}});
      if (!this.isDestroying) { this.requestData = data; }
    } catch (error) { if (!this.isDestroying) { this.error = extractError(error); } }
    finally { if (!this.isDestroying) { this.busy = false; } }
  }
  @action
  setReviewReason(id, event) { this.reviewReasons = {...this.reviewReasons, [id]: event.target.value}; }
  @action
  async reviewListing(id, decision) {
    if (this.busy) { return; }
    this.busy = true; this.error = "";
    try {
      await ajax("/rsc/forecast/requests/review.json", {type: "POST", data: {external_id: id, decision, reason: this.reviewReasons[id] || "", request_id: crypto.randomUUID()}});
      if (!this.isDestroying) { await this.loadRequests(); await this.reload(); this.notice = ft("review_saved"); }
    } catch (error) { if (!this.isDestroying) { this.error = extractError(error); } }
    finally { if (!this.isDestroying) { this.busy = false; } }
  }

  @action
  setSearch(event) { this.search = event.target.value; }

  clearQuote() { this.quote = null; this.requestId = null; clearInterval(this.timer); }
  @action
  setAmount(event) { this.amount = event.target.value; this.clearQuote(); }

  @action
  setSide(side) { this.side = side; this.amount = side === "sell" ? (this.currentHolding?.shares || "") : "10"; this.clearQuote(); }

  @action
  setOutcome(index) { this.outcome = index; this.clearQuote(); if (this.side === "sell") { this.amount = this.currentHolding?.shares || ""; } this.loadHistory(); }

  @action
  setInterval(interval) { this.interval = interval; this.loadHistory(); }

  async loadHistory() {
    if (this.detail?.preview) { return; }
    const version = ++this.historyVersion;
    this.chartLoading = true;
    this.chartError = "";
    this.history = [];
    try {
      const data = await ajax(`/rsc/forecast/markets/${this.detail.id}/history.json`, { data: { outcome: this.outcome, interval: this.interval } });
      if (!this.isDestroying && version === this.historyVersion) { this.history = data.points; }
    } catch (error) {
      if (!this.isDestroying && version === this.historyVersion) { this.chartError = extractError(error); }
    } finally {
      if (!this.isDestroying && version === this.historyVersion) { this.chartLoading = false; }
    }
  }

  async reload() {
    const [data, detail] = await Promise.all([
      ajax("/rsc/forecast/state.json"),
      this.detail && !this.detail.preview ? ajax(`/rsc/forecast/markets/${this.detail.id}.json`) : Promise.resolve(this.detail),
    ]);
    if (!this.isDestroying) { this.data = data; this.detail = detail; }
  }

  @action
  async refresh() {
    if (this.busy) { return; }
    this.busy = true; this.error = "";
    try { await this.reload(); if (this.section === "browse") { await this.loadCatalog(this.catalog.page); } }
    catch (error) { if (!this.isDestroying) { this.error = extractError(error); } }
    finally { if (!this.isDestroying) { this.busy = false; } }
  }

  @action
  async preview(event) {
    event.preventDefault();
    if (this.tradeDisabled) { return; }
    this.busy = true; this.error = ""; this.notice = ""; this.clearQuote();
    try {
      const quote = await ajax(`/rsc/forecast/markets/${this.detail.id}/quote.json`, { type: "POST", data: { outcome: this.outcome, side: this.side, amount: this.amount } });
      if (this.isDestroying) { return; }
      this.quote = quote; this.requestId = `forecast-${quote.token}`;
      const tick = () => { this.seconds = Math.max(0, Math.floor((new Date(quote.expires_at).getTime() - Date.now()) / 1000)); if (!this.seconds) { clearInterval(this.timer); } };
      tick(); this.timer = setInterval(tick, 1000);
    } catch (error) { if (!this.isDestroying) { this.error = extractError(error); } }
    finally { if (!this.isDestroying) { this.busy = false; } }
  }

  @action
  async confirm() {
    if (!this.quote || this.confirmationDisabled) { return; }
    this.busy = true; this.error = "";
    try {
      await ajax("/rsc/forecast/trades.json", { type: "POST", data: { token: this.quote.token, request_id: this.requestId } });
      if (this.isDestroying) { return; }
      this.clearQuote(); this.notice = ft("success");
      await this.reload();
    } catch (error) { if (!this.isDestroying) { this.error = extractError(error); } }
    finally { if (!this.isDestroying) { this.busy = false; } }
  }

  <template>
    <div class="rsc-app rsc-forecast">
      <RscNavigation />
      <div class="forecast-toolbar">
        <div class="forecast-tabs">
          <button class={{if (eq this.section "popular") "is-active"}} type="button" {{on "click" (fn this.setSection "popular")}}>{{ft "popular"}}</button>
          <button class={{if (eq this.section "browse") "is-active"}} type="button" {{on "click" (fn this.setSection "browse")}}>{{ft "browse"}}</button>
          <button class={{if (eq this.section "joined") "is-active"}} type="button" {{on "click" (fn this.setSection "joined")}}>{{ft "joined"}}</button>
          <button class={{if (eq this.section "requests") "is-active"}} type="button" {{on "click" (fn this.setSection "requests")}}>{{ft "my_requests"}}</button>
          {{#if this.data.admin}}<button class={{if (eq this.section "review") "is-active"}} type="button" {{on "click" (fn this.setSection "review")}}>{{ft "review_requests"}}</button>{{/if}}
          <button class={{if (eq this.section "holdings") "is-active"}} type="button" {{on "click" (fn this.setSection "holdings")}}>{{ft "holdings"}}</button>
          <button class={{if (eq this.section "history") "is-active"}} type="button" {{on "click" (fn this.setSection "history")}}>{{ft "history"}}</button>
        </div>
        {{#if (eq this.section "popular")}}{{#unless this.detail}}<input aria-label={{ft "search"}} class="forecast-search" placeholder={{ft "search"}} type="search" value={{this.search}} {{on "input" this.setSearch}} />{{/unless}}{{/if}}
        <div class="forecast-account"><span>{{ft "balance"}} <strong>{{pretty this.data.balance 2}} RSC</strong></span><button aria-label={{ft "refresh"}} class="btn btn-flat" disabled={{this.busy}} title={{ft "refresh"}} type="button" {{on "click" this.refresh}}>{{dIcon "arrows-rotate"}}</button></div>
      </div>
      {{#if this.error}}<div class="forecast-notice forecast-error" role="alert">{{this.error}}</div>{{/if}}
      {{#if this.notice}}<div class="forecast-notice" role="status">{{this.notice}}</div>{{/if}}
      {{#if this.data.read_only}}<p class="forecast-notice">{{ft "read_only"}}</p>{{/if}}
      {{#if (eq this.section "browse")}}
        <form class="forecast-browse-filters" {{on "submit" this.searchCatalog}}>
          <input aria-label={{ft "catalog_search"}} placeholder={{ft "catalog_search"}} type="search" value={{this.catalogQuery}} {{on "input" this.setCatalogQuery}} />
          <select aria-label={{ft "categories"}} value={{this.catalogCategory}} {{on "change" this.setCatalogCategory}}>{{#each this.catalogCategories as |category|}}<option value={{category.key}} selected={{eq this.catalogCategory category.key}}>{{category.label}}</option>{{/each}}</select>
          <select aria-label={{ft "catalog_sort"}} value={{this.catalogOrder}} {{on "change" this.setCatalogOrder}}><option value="balanced" selected={{eq this.catalogOrder "balanced"}}>{{ft "sort_balanced"}}</option><option value="popular" selected={{eq this.catalogOrder "popular"}}>{{ft "sort_popular"}}</option><option value="newest" selected={{eq this.catalogOrder "newest"}}>{{ft "sort_newest"}}</option></select>
          <button class="btn btn-primary" disabled={{this.catalogLoading}} type="submit">{{ft "search_button"}}</button>
        </form>
        <p class="forecast-hint">{{ft "browse_hint"}} · {{this.catalog.total}} {{#if this.catalog.grouped}}{{ft "events"}}{{else}}{{ft "questions"}}{{/if}}</p>
        {{#if this.catalogEvent}}<button class="btn btn-flat" type="button" {{on "click" (fn this.browseEvent "")}}>{{ft "back_events"}}</button>{{/if}}
        {{#if this.catalogLoading}}<p role="status">{{ft "loading"}}</p>{{/if}}
        <div class="forecast-grid">{{#each this.catalog.markets key="external_id" as |market|}}<article class="forecast-card">
          <button class="forecast-card-title forecast-preview-link" disabled={{this.busy}} type="button" {{on "click" (fn this.previewCatalog market.external_id)}}>{{market.question}}</button>
          <div class="forecast-event">{{categoryLabel market.category}} · {{market.event_title}}</div>
          {{#if (gt market.related_count 1)}}<button class="btn btn-flat forecast-related" type="button" {{on "click" (fn this.browseEvent market.event_id)}}>{{ft "related"}} · {{market.related_count}}</button>{{/if}}
          <div class="forecast-outcomes">{{#each (options market) as |choice|}}<div class="forecast-outcome"><span>{{choice.name}}</span><strong>{{choice.probability}}</strong></div>{{/each}}</div>
          <div class="forecast-card-footer"><span>{{ft "volume"}} ${{pretty market.volume 0}}</span><span>{{#if market.market_id}}{{ft "request_approved"}}{{else}}{{requestStatus market.request_status}}{{/if}}</span></div>
        </article>{{else}}<p class="forecast-hint">{{ft "catalog_empty"}}</p>{{/each}}</div>
        <div class="forecast-pagination"><button class="btn" disabled={{this.previousDisabled}} type="button" {{on "click" (fn this.pageCatalog -1)}}>{{ft "previous"}}</button><span>{{this.catalog.page}} / {{this.catalog.pages}}</span><button class="btn" disabled={{this.nextDisabled}} type="button" {{on "click" (fn this.pageCatalog 1)}}>{{ft "next"}}</button></div>
      {{else if (eq this.section "joined")}}
        <p class="forecast-hint">{{ft "joined_hint"}}</p>
        <div class="forecast-grid">{{#each this.data.joined as |market|}}<article class="forecast-card"><LinkTo class="forecast-card-title" @query={{hash section=null market_id=market.id}} @route="rsc.forecast">{{market.question}}</LinkTo><div class="forecast-outcomes">{{#each (options market) as |choice|}}<LinkTo class="forecast-outcome" @query={{hash section=null market_id=market.id outcome=choice.index}} @route="rsc.forecast"><span>{{choice.name}}</span><strong>{{choice.probability}}</strong></LinkTo>{{/each}}</div><small>{{status market.state}}</small></article>{{else}}<p class="forecast-hint">{{ft "no_joined"}}</p>{{/each}}</div>
      {{else if (eq this.section "requests")}}
        {{#each this.requestData.mine key="id" as |request|}}<article class="forecast-position"><div class="forecast-position-heading"><button class="forecast-preview-link" type="button" {{on "click" (fn this.previewCatalog request.external_id)}}>{{request.question}}</button><strong>{{requestStatus request.status}}</strong></div><p>{{request.reason}}</p>{{#if request.review_reason}}<p class="forecast-hint">{{request.review_reason}}</p>{{/if}}{{#if request.market_id}}<LinkTo @query={{hash section=null market_id=request.market_id}} @route="rsc.forecast">{{ft "open_trading"}}</LinkTo>{{/if}}<small>{{when request.created_at}}</small></article>{{else}}<p class="forecast-hint">{{ft "no_requests"}}</p>{{/each}}
      {{else if (eq this.section "review")}}
        {{#each this.pendingRequests key="id" as |request|}}<article class="forecast-position"><div class="forecast-position-heading"><button class="forecast-preview-link" type="button" {{on "click" (fn this.previewCatalog request.external_id)}}>{{request.question}}</button><small>{{when request.created_at}}</small></div><p>{{request.reason}}</p><div class="forecast-review-actions"><input aria-label={{ft "review_reason"}} placeholder={{ft "review_reason"}} value={{request.reviewReason}} {{on "input" (fn this.setReviewReason request.external_id)}} /><button class="btn btn-primary" disabled={{this.reviewDisabled}} type="button" {{on "click" (fn this.reviewListing request.external_id "approved")}}>{{ft "approve"}}</button><button class="btn" disabled={{this.reviewDisabled}} type="button" {{on "click" (fn this.reviewListing request.external_id "rejected")}}>{{ft "reject"}}</button></div></article>{{else}}<p class="forecast-hint">{{ft "no_pending"}}</p>{{/each}}
      {{else if (eq this.section "holdings")}}
        {{#each this.data.holdings as |position|}}
          <article class="forecast-position">
            <div class="forecast-position-heading"><LinkTo @query={{hash section=null market_id=position.market_id outcome=position.outcome}} @route="rsc.forecast" {{on "click" (fn this.setSection "popular")}}>{{position.question}}</LinkTo><small>{{status position.state}}</small></div>
            <div class="forecast-position-data"><strong>{{outcomeLabel position.label}}</strong><span>{{ft "shares"}} {{pretty position.shares 6}}</span><span>{{ft "cost"}} {{pretty position.cost}} RSC</span><span class={{tone position.realized}}>{{ft "realized"}} {{signed position.realized}} RSC</span></div>
          </article>
        {{else}}<p class="forecast-hint">{{ft "no_holdings"}}</p>{{/each}}
      {{else if (eq this.section "history")}}
        <div class="forecast-table-wrap"><table class="forecast-table"><thead><tr><th>{{ft "question"}}</th><th>{{ft "side"}}</th><th>{{ft "shares"}}</th><th>RSC</th><th>{{ft "realized"}}</th><th>{{ft "time"}}</th></tr></thead><tbody>
          {{#each this.data.trades as |trade|}}<tr><td><LinkTo @query={{hash section=null market_id=trade.market_id outcome=trade.outcome_index}} @route="rsc.forecast" {{on "click" (fn this.setSection "popular")}}>{{trade.question}}</LinkTo><br /><small>{{outcomeLabel trade.outcome}}</small></td><td>{{ft trade.side}}</td><td>{{pretty trade.shares 6}}</td><td>{{pretty trade.cash}}</td><td class={{tone trade.pnl}}>{{#if (eq trade.side "buy")}}—{{else}}{{signed trade.pnl}}{{/if}}</td><td>{{when trade.at}}</td></tr>
          {{else}}<tr><td colspan="6">{{ft "no_trades"}}</td></tr>{{/each}}
        </tbody></table></div><p class="forecast-hint">{{ft "recent_trades"}}</p>
      {{else if this.detail}}
        <div class="forecast-detail-top">{{#if this.detail.preview}}<button class="btn btn-flat" type="button" {{on "click" this.closePreview}}>{{dIcon "arrow-left"}} {{ft "back_browse"}}</button>{{else}}<LinkTo @query={{hash section=null market_id=null}} @route="rsc.forecast">{{dIcon "arrow-left"}} {{ft "back"}}</LinkTo>{{/if}}<a href={{this.detail.url}} rel="noopener noreferrer" target="_blank">Polymarket ↗</a></div>
        <div class="forecast-detail">
          <div class="forecast-main">
            <h1>{{this.detailQuestion}}</h1>
            {{#if this.detail.translated}}<div class="forecast-translation"><small>{{ft "translated_hint"}}</small><button class="btn btn-flat" type="button" {{on "click" this.toggleOriginal}}>{{#if this.showOriginal}}{{ft "show_chinese"}}{{else}}{{ft "show_original"}}{{/if}}</button></div>{{/if}}
            <div class="forecast-meta"><span>{{status this.detail.state}}</span><span>{{ft "ends"}} {{when this.detail.ends_at}}</span><span>{{ft "volume"}} ${{pretty this.detail.volume 0}}</span><span>{{ft "updated"}} {{when this.detail.synced_at}}</span></div>
            {{#if this.result}}<p class="forecast-notice">{{ft "resolved_payout"}} {{this.result}}</p>{{/if}}
            {{#unless this.detail.preview}}<div class="forecast-chart">
              <div class="forecast-chart-heading"><strong>{{this.selectedLabel}} {{this.selectedProbability}}</strong><div class="forecast-periods">
                <button class={{if (eq this.interval "1d") "is-active"}} type="button" {{on "click" (fn this.setInterval "1d")}}>{{ft "day"}}</button>
                <button class={{if (eq this.interval "1w") "is-active"}} type="button" {{on "click" (fn this.setInterval "1w")}}>{{ft "week"}}</button>
                <button class={{if (eq this.interval "1m") "is-active"}} type="button" {{on "click" (fn this.setInterval "1m")}}>{{ft "month"}}</button>
                <button class={{if (eq this.interval "max") "is-active"}} type="button" {{on "click" (fn this.setInterval "max")}}>{{ft "all"}}</button>
              </div></div>
              {{#if this.chartLoading}}<div class="forecast-chart-empty">{{ft "loading"}}</div>
              {{else if this.chartError}}<div class="forecast-chart-empty">{{this.chartError}}</div>
              {{else if this.points}}<div class="forecast-chart-plot"><div aria-hidden="true" class="forecast-chart-axis"><span>100%</span><span>50%</span><span>0%</span></div><svg aria-label={{ft "chart"}} preserveAspectRatio="none" role="img" viewBox="0 0 600 200"><line x1="30" x2="590" y1="20" y2="20" /><line x1="30" x2="590" y1="100" y2="100" /><line x1="30" x2="590" y1="180" y2="180" /><polyline points={{this.points}} /></svg></div>
              {{else}}<div class="forecast-chart-empty">{{ft "no_chart"}}</div>{{/if}}
              <div class="forecast-chart-range"><span>{{this.historyStart}}</span><span>{{this.historyEnd}}</span></div>
            </div>
            {{/unless}}<details class="forecast-rules" open><summary>{{ft "rules"}}</summary><p>{{this.detailRules}}</p></details>
            <p class="forecast-hint forecast-resolution-hint">{{ft "resolution_hint"}}</p>
          </div>
          <aside aria-label={{ft "order"}} class="forecast-order">
            {{#if this.detail.preview}}
              <div class="forecast-outcomes">{{#each this.choices as |choice|}}<div class="forecast-outcome"><span>{{choice.name}}</span><strong>{{choice.probability}}</strong></div>{{/each}}</div>
              {{#if this.detail.market_id}}<LinkTo class="btn btn-primary" @query={{hash section=null market_id=this.detail.market_id}} @route="rsc.forecast">{{ft "open_trading"}}</LinkTo>
              {{else}}
                <h3>{{requestStatus this.detail.request_status}}</h3><p class="forecast-hint">{{ft "apply_hint"}}</p>
                {{#if this.detail.review_reason}}<p>{{this.detail.review_reason}}</p>{{/if}}
                <form {{on "submit" this.submitListing}}><label>{{ft "request_reason"}}<textarea maxlength="500" value={{this.requestReason}} {{on "input" this.setRequestReason}}></textarea></label><button class="btn btn-primary" disabled={{this.requestDisabled}} type="submit">{{ft "apply"}}</button></form>
              {{/if}}
            {{else}}
            <div class="forecast-tabs"><button class={{if (eq this.side "buy") "is-active"}} disabled={{this.busy}} type="button" {{on "click" (fn this.setSide "buy")}}>{{ft "buy"}}</button><button class={{if (eq this.side "sell") "is-active"}} disabled={{this.busy}} type="button" {{on "click" (fn this.setSide "sell")}}>{{ft "sell"}}</button></div>
            <div class="forecast-outcomes">{{#each this.choices as |choice|}}<button class="forecast-outcome {{if (eq choice.index this.outcome) 'selected'}}" disabled={{this.busy}} type="button" {{on "click" (fn this.setOutcome choice.index)}}><span>{{choice.name}}</span><strong>{{choice.probability}}</strong></button>{{/each}}</div>
            <div class="forecast-order-line"><span>{{ft "available_shares"}}</span><strong>{{#if this.currentHolding}}{{pretty this.currentHolding.shares 6}}{{else}}0{{/if}}</strong></div>
            <form {{on "submit" this.preview}}><label>{{#if (eq this.side "buy")}}{{ft "budget"}}{{else}}{{ft "sell_shares"}}{{/if}}<input disabled={{this.busy}} min="0.000001" step="0.000001" type="number" value={{this.amount}} {{on "input" this.setAmount}} /></label><button class="btn btn-primary" disabled={{this.tradeDisabled}} type="submit">{{#if this.busy}}{{ft "loading"}}{{else}}{{ft "preview"}}{{/if}}</button></form>
            {{#if this.quote}}<div aria-live="polite" class="forecast-quote"><div class="forecast-order-line"><span>{{ft "average"}}</span><strong>{{pretty this.quote.average 4}} RSC</strong></div><div class="forecast-order-line"><span>{{ft "shares"}}</span><strong>{{pretty this.quote.shares 6}}</strong></div><div class="forecast-order-line"><span>{{#if (eq this.side "buy")}}{{ft "pay"}}{{else}}{{ft "receive"}}{{/if}}</span><strong>{{pretty this.quote.cash}} RSC</strong></div>{{#if (eq this.side "buy")}}<div class="forecast-order-line"><span>{{ft "multiple"}}</span><strong>{{pretty this.quote.multiple 2}}×</strong></div><div class="forecast-order-line"><span>{{ft "if_wins"}}</span><strong>{{pretty this.quote.potential_payout}} RSC</strong></div>{{/if}}<button class="btn btn-primary" disabled={{this.confirmationDisabled}} type="button" {{on "click" this.confirm}}>{{ft "confirm"}} · {{this.seconds}}s</button></div>{{/if}}
            <p class="forecast-hint">{{ft "trade_hint"}}</p>{{/if}}
          </aside>
        </div>
      {{else}}
        <nav aria-label={{ft "categories"}} class="forecast-categories">
          {{#each this.categories as |category|}}<button class={{if (eq this.category category.key) "is-active"}} aria-pressed={{eq this.category category.key}} type="button" {{on "click" (fn this.setCategory category.key)}}>{{category.label}} <small>{{category.count}}</small></button>{{/each}}
        </nav>
        <div class="forecast-grid">{{#each this.markets as |market|}}<article class="forecast-card"><div class="forecast-card-top"><span aria-hidden="true" class="forecast-mark">{{dIcon "chart-line"}}</span><LinkTo class="forecast-card-title" @query={{hash section=null market_id=market.id outcome=0}} @route="rsc.forecast">{{market.question}}</LinkTo></div><div class="forecast-event" title={{market.event_title}}>{{market.event_title}}</div><div class="forecast-outcomes">{{#each (options market) as |choice|}}<LinkTo class="forecast-outcome" @query={{hash section=null market_id=market.id outcome=choice.index}} @route="rsc.forecast"><span>{{choice.name}}</span><strong>{{choice.probability}}</strong></LinkTo>{{/each}}</div><div class="forecast-card-footer"><span>{{ft "volume"}} ${{pretty market.volume 0}}</span><span>{{status market.state}}</span></div></article>{{else}}<p class="forecast-hint">{{ft "empty"}}</p>{{/each}}</div>
        <p class="forecast-hint">{{ft "source_hint"}}</p>
      {{/if}}
    </div>
  </template>
}
