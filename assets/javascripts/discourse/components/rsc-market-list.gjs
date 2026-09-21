import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { debounce, cancel } from "@ember/runloop";
import { ajax } from "discourse/lib/ajax";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { i18n } from "discourse-i18n";
import { formatPrice } from "../lib/rsc-format";
import { marketView, sparkline } from "../lib/rsc-market";
const uiText = (value) => i18n(`discourse_rsc.ui.${value}`);
export default class extends Component {
  @tracked search = "";
  @tracked category = "all";
  @tracked page = 1;
  @tracked sort = "popular";
  constructor() {
    super(...arguments);
    this.category = this.args.instruments.some((item) => marketView(item, Date.now()).tradable) ? "tradable" : "all";
    try {
      const saved = JSON.parse(
        sessionStorage.getItem("rsc:market-filters:v2") || "{}"
      );
      this.search = typeof saved.search === "string" ? saved.search : "";
      this.category =
        ["all", "tradable"].includes(saved.category) ||
        this.args.instruments.some((item) => item.category === saved.category)
          ? saved.category
          : this.category;
      this.sort = ["popular", "symbol", "gainers", "losers"].includes(
        saved.sort
      )
        ? saved.sort
        : "popular";
      this.page =
        Number.isInteger(saved.page) && saved.page > 0 ? saved.page : 1;
    } catch {
      /* Storage can be disabled by the browser. */
    }
  }
  remember() {
    try {
      sessionStorage.setItem(
        "rsc:market-filters:v2",
        JSON.stringify({
          search: this.search,
          category: this.category,
          sort: this.sort,
          page: this.page,
        })
      );
    } catch {
      /* Optional preference. */
    }
  }
  get categories() {
    return [
      "all",
      "tradable",
      ...new Set(this.args.instruments.map((item) => item.category)),
    ].map((id) => ({
      id,
      name: i18n(`discourse_rsc.ui.category_${id}`, {
        defaultValue: id.toUpperCase(),
      }),
    }));
  }
  get filtered() {
    const query = this.search.trim().toLocaleLowerCase();
    const result = this.args.instruments
      .filter(
        (item) =>
          (this.category === "all" ||
            this.category === "tradable" ||
            this.category === item.category) &&
          `${item.symbol} ${item.display_symbol || ""} ${item.exchange || ""} ${item.currency || ""} ${item.name} ${item.category}`
            .toLocaleLowerCase()
            .includes(query)
      )
      .map((item) => marketView(item, this.args.now))
      .filter((item) => this.category !== "tradable" || item.tradable);
    if (this.sort === "symbol") {
      result.sort((a, b) => a.symbol.localeCompare(b.symbol));
    }
    if (this.sort === "gainers") {
      result.sort((a, b) => (b.change ?? -Infinity) - (a.change ?? -Infinity));
    }
    if (this.sort === "losers") {
      result.sort((a, b) => (a.change ?? Infinity) - (b.change ?? Infinity));
    }
    return result;
  }
  get pageCount() {
    return Math.max(1, Math.ceil(this.filtered.length / 20));
  }
  get currentPage() {
    return Math.min(this.page, this.pageCount);
  }
  get rows() {
    return this.filtered.slice(
      (this.currentPage - 1) * 20,
      this.currentPage * 20
    );
  }
  get firstPage() {
    return this.currentPage === 1;
  }
  get lastPage() {
    return this.currentPage === this.pageCount;
  }
  @action filter(event) {
    this.search = event.target.value;
    this.searchTimer = debounce(this, this.recordSearch, 1200);
    this.page = 1;
    this.remember();
  }
  recordSearch() {
    const query = this.search.trim();
    if (this.args.readOnly || query.length < 2) { return; }
    // Analytics must not interrupt market browsing when unavailable.
    ajax("/rsc/search-events.json", { type: "POST", data: { q: query, result_count: this.filtered.length } }).catch(() => {});
  }
  willDestroy() { super.willDestroy(...arguments); cancel(this.searchTimer); }
  @action chooseCategory(category) {
    this.category = category;
    this.page = 1;
    this.remember();
  }
  @action changeSort(event) {
    this.sort = event.target.value;
    this.page = 1;
    this.remember();
  }
  @action previous() {
    this.page = Math.max(1, this.currentPage - 1);
    this.remember();
  }
  @action next() {
    this.page = Math.min(this.pageCount, this.currentPage + 1);
    this.remember();
  }
  <template>
    <section class="rsc-market-board" aria-label={{uiText "market_quotes"}}>
      <div class="rsc-board-heading"><div><p class="rsc-eyebrow">MARKETS</p><h2
          >{{uiText "market_quotes"}}</h2></div><span
          class="rsc-count"
        >{{this.filtered.length}} {{uiText "instruments_count"}}</span></div>
      <div
        class="rsc-category-strip"
        aria-label={{uiText "market_categories"}}
      >{{#each this.categories as |category|}}<button
            type="button"
            class={{if (eq this.category category.id) "active" ""}}
            aria-pressed={{eq this.category category.id}}
            {{on "click" (fn this.chooseCategory category.id)}}
          >{{category.name}}</button>{{/each}}</div>
      <div class="rsc-board-tools"><label class="rsc-search"><span
            aria-hidden="true"
          >⌕</span><input
            type="search"
            aria-label={{uiText "search_markets"}}
            placeholder={{uiText "search_markets"}}
            value={{this.search}}
            {{on "input" this.filter}}
          /></label><select
          aria-label={{uiText "sort_markets"}}
          {{on "change" this.changeSort}}
        ><option value="popular" selected={{eq this.sort "popular"}}>{{uiText
              "popular"
            }}</option><option
            value="symbol"
            selected={{eq this.sort "symbol"}}
          >{{uiText "sort_symbol"}}</option><option
            value="gainers"
            selected={{eq this.sort "gainers"}}
          >{{uiText "gainers"}}</option><option
            value="losers"
            selected={{eq this.sort "losers"}}
          >{{uiText "losers"}}</option></select></div>
      <div class="rsc-quote-head" aria-hidden="true"><span>{{uiText
            "instrument"
          }}</span><span>{{uiText "latest_price"}}</span><span>{{uiText
            "daily_change"
          }}</span></div>
      <div class="rsc-quote-list">{{#each this.rows as |item|}}
          <div class="rsc-quote-item"><button
              type="button"
              class="rsc-quote-row {{if (eq @selectedId item.id) 'selected'}}"
              aria-pressed={{eq @selectedId item.id}}
              aria-label={{item.symbol}}
              {{on "click" (fn @onSelect item.id)}}
            >
              <span class="rsc-quote-identity"><strong
                >{{item.display_symbol}}</strong><span
                >{{item.name}}</span><small
                  class="rsc-market-status {{item.status}}"
                >{{uiText item.status}}</small></span>
              <span class="rsc-quote-price"><strong
                  title={{item.quote.price}}
                >{{formatPrice item.quote.price}}</strong><small
                >{{item.localPrice}}</small></span>
              <span class="rsc-quote-change {{item.tone}}"><strong
                >{{item.changeText}}</strong><svg
                  viewBox="0 0 600 150"
                  aria-hidden="true"
                ><polyline
                    points={{sparkline item.history}}
                    fill="none"
                    stroke="currentColor"
                    stroke-width="10"
                  /></svg></span>
            </button><div class="rsc-quote-actions"><button
                type="button"
                class="btn btn-small positive"
                disabled={{@readOnly}}
                {{on "click" (fn @onTrade item.id "long")}}
              >{{uiText "long"}}</button><button
                type="button"
                class="btn btn-small negative"
                disabled={{@readOnly}}
                {{on "click" (fn @onTrade item.id "short")}}
              >{{uiText "short"}}</button></div></div>
        {{else}}<div class="rsc-empty"><strong>{{uiText
                "no_results"
              }}</strong><p>{{uiText "search_hint"}}</p></div>{{/each}}</div>
      <div class="rsc-list-footer"><span>{{uiText "auto_refresh"}}</span><div
        ><button
            type="button"
            aria-label={{uiText "previous_page"}}
            disabled={{this.firstPage}}
            {{on "click" this.previous}}
          >‹</button><span>{{this.currentPage}}
            /
            {{this.pageCount}}</span><button
            type="button"
            aria-label={{uiText "next_page"}}
            disabled={{this.lastPage}}
            {{on "click" this.next}}
          >›</button></div></div>
    </section>
  </template>
}
