import RscNavigation from "./rsc-navigation";
import ForumUser from "./rsc-user";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { on } from "@ember/modifier";
import { eq } from "discourse/truth-helpers";
import { fn } from "@ember/helper";
import { LinkTo } from "@ember/routing";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import RscPagination from "./rsc-pagination";
import RscAdminTools from "./rsc-admin-tools";
import { formatAmount } from "../lib/rsc-format";
import { i18n } from "discourse-i18n";
const uiText = (key) => i18n(`discourse_rsc.ui.${key}`);
const categoryText = (key) => uiText(`category_${key}`);
const json = (value) => JSON.stringify(value, null, 2);
const fields = {
  seed_catalog: [],
  manual_quote: [
    "id",
    "price",
    "previous_close",
    "session_start",
    "session_end",
  ],
  wallet_status: ["user_id", "status"],
  reset_assets: ["user_id", "reset_mode", "amount", "clear_positions"],
  exemption: ["user_id", "starts_at", "expires_at"],
  instrument: [
    "symbol",
    "name",
    "provider",
    "provider_symbol",
    "category",
    "asset_type",
    "currency",
    "minimum",
    "step",
    "fee_bps",
    "active",
  ],
  reject_request: ["id"],
  match_result: ["id", "result"],
  issuance: ["user_id", "amount"],
};
const operations = Object.keys(fields);
const options = {
  reset_mode: ["cash", "total_equity"],
  asset_type: ["stock", "etf", "etn", "fund", "crypto", "index", "forex", "metal"],
  status: ["frozen", "active"],
  clear_positions: ["false", "true"],
  provider: ["yahoo", "coinbase", "twelve_data", "kraken", "okx", "manual"],
  active: ["true", "false"],
  result: ["home", "away", "draw", "canceled"],
  category: [
    "us",
    "hk",
    "cn",
    "crypto",
    "indices",
    "forex",
    "metals",
    "jp",
    "eu",
    "sg",
    "ca",
    "au",
    "in",
  ],
};
export default class extends Component {
  @service currentUser;
  @tracked data;
  @tracked operation = "wallet_status";
  @tracked draft = { status: "frozen" };
  @tracked query = "";
  @tracked instrumentQuery = "";
  @tracked instrumentCategory = "";
  @tracked pages = {};
  @tracked date = "";
  @tracked rewards;
  @tracked rewardFilter = "all";
  @tracked rewardPage = 1;
  @tracked campaign;
  @tracked error = "";
  @tracked notice = "";
  @tracked busy = false;
  requests = new Map();
  constructor() {
    super(...arguments);
    this.data = this.args.model;
  }
  get formFields() {
    return [...fields[this.operation], "reason"].map((key) => ({
      key,
      options: options[key],
      required: key !== "starts_at",
      value: this.draft[key] || "",
    }));
  }
  @action choose(event) {
    this.operation = event.target.value;
    this.draft = Object.fromEntries(
      fields[this.operation]
        .filter((key) => options[key])
        .map((key) => [key, options[key][0]])
    );
  }
  @action change(key, event) {
    this.draft = { ...this.draft, [key]: event.target.value };
  }
  @action queryChange(event) {
    this.query = event.target.value;
  }
  @action dateChange(event) {
    this.date = event.target.value;
  }
  @action async search(event) {
    event?.preventDefault();
    this.pages = { ...this.pages, wallet_page: 1 };
    await this.refresh();
  }
  @action async instrumentCategoryChanged(event) { this.instrumentCategory = event.target.value; this.pages = { ...this.pages, instrument_page: 1 }; await this.refresh(); }
  @action instrumentQueryChanged(event) { this.instrumentQuery = event.target.value; }
  @action async instrumentSearch(event) { event.preventDefault(); this.pages = { ...this.pages, instrument_page: 1 }; await this.refresh(); }
  @action async pageChanged(kind, page) { this.pages = { ...this.pages, [`${kind}_page`]: page }; await this.refresh(); }
  @action async refresh() {
    try {
      this.data = await ajax("/rsc/admin/state.json", {
        data: { q: this.query, instrument_q: this.instrumentQuery, instrument_category: this.instrumentCategory, ...this.pages },
      });
    } catch (error) {
      this.error = extractError(error);
    }
  }
  async post(path, data) {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.error = "";
    this.notice = "";
    const key = JSON.stringify([path, data]);
    const id = this.requests.get(key) || crypto.randomUUID();
    this.requests.set(key, id);
    try {
      const result = await ajax(`/rsc/${path}.json`, {
        type: "POST",
        data: { ...data, request_id: id },
      });
      this.requests.delete(key);
      this.notice = uiText("saved");
      await this.refresh();
      return result;
    } catch (error) {
      this.error = extractError(error);
    } finally {
      this.busy = false;
    }
  }
  @action submit(event) {
    event.preventDefault();
    return this.operation === "issuance"
      ? this.post("issuances", {
          recipient_user_id: this.draft.user_id,
          amount: this.draft.amount,
          reason: this.draft.reason,
        })
      : this.post("admin/action", {
          operation: this.operation,
          input: this.draft,
        });
  }
  @action sync() {
    return this.post("admin/sync", {});
  }
  @action async preview(pay) {
    if (pay) {
      const result = await this.post("admin/rewards", { date: this.date, pay });
      if (result) { this.rewards = result.rows; this.rewardPage = 1; }
      return;
    }
    this.error = "";
    try {
      const result = await ajax("/rsc/admin/rewards.json", { data: { date: this.date } });
      this.rewards = result.rows; this.rewardPage = 1;
    } catch (error) {
      this.error = extractError(error);
    }
  }
  get writeDisabled() { return this.busy || this.data.read_only; }
  @action filterRewards(event) { this.rewardFilter = event.target.value; this.rewardPage = 1; }
  get filteredRewards() { return (this.rewards || []).filter((row) => this.rewardFilter === "all" || (this.rewardFilter === "paid" && row.paid) || (this.rewardFilter === "frozen" && row.frozen) || (this.rewardFilter === "pending" && !row.paid && !row.frozen && row.score > 0)); }
  @action changeRewardPage(page) { this.rewardPage = page; }
  get rewardPagination() { return { page: this.rewardPage, pages: Math.max(1, Math.ceil(this.filteredRewards.length / 20)), total: this.filteredRewards.length }; }
  get rewardRows() { return this.filteredRewards.slice((this.rewardPage - 1) * 20, this.rewardPage * 20); }
  get pendingRewardAmount() { return (this.rewards || []).filter((row) => !row.paid && !row.frozen).reduce((sum,row) => sum + row.score,0); }
  @action async campaignPreview() {
    try {
      this.campaign = await ajax("/rsc/admin/campaign.json");
    } catch (error) {
      this.error = extractError(error);
    }
  }
  @action async campaignApply() {
    const result = await this.post("admin/campaign", {});
    if (result) {
      this.campaign = result;
    }
  }
  get campaignDisabled() {
    return (
      this.busy ||
      this.data.read_only ||
      !this.campaign?.ready ||
      !this.campaign?.pending
    );
  }
  <template>
    <main class="rsc-app rsc-admin-page"><RscNavigation />{{#unless this.currentUser.rsc_member}}<div class="rsc-breadcrumb"><LinkTo @route="discovery.latest">← {{uiText "back_to_forum"}}</LinkTo></div>{{/unless}}<h1 class="sr-only">{{uiText "administration"}}</h1>
      {{#unless this.currentUser.rsc_member}}<div class="alert alert-info" role="status">{{uiText "admin_without_membership"}}</div>{{/unless}}
      {{#if this.error}}<div
          class="alert alert-error"
          role="alert"
        >{{this.error}}</div>{{/if}}{{#if this.notice}}<div
          class="alert alert-success"
          role="status"
        >{{this.notice}}</div>{{/if}}
      <div class="rsc-market-summary"><div>{{uiText "circulating"}}<strong
          >{{formatAmount this.data.stats.circulating}} RSC</strong></div><div>{{uiText
            "escrow"
          }}<strong>{{formatAmount this.data.stats.escrow}} RSC</strong></div><div>{{uiText
            "wallets"
          }}<strong>{{this.data.stats.wallets}}</strong></div><div>{{uiText
            "journals"
          }}<strong>{{this.data.stats.journals}}</strong></div></div>
      {{#if this.data.read_only}}<p class="alert alert-info">{{uiText
            "read_only"
          }}</p>{{/if}}
      <section class="rsc-card"><h2>{{uiText "market_health"}}</h2><p>{{uiText
            "fresh_quotes"
          }}:
          {{this.data.market_health.fresh}}
          /
          {{this.data.market_health.exposed}}</p>{{#unless
          this.data.market_health.capacity_ok
        }}<p class="alert alert-error">{{uiText
              "quote_capacity"
            }}</p>{{/unless}}{{#if
          this.data.market_health.stale.length
        }}<details><summary>{{uiText "stale_quotes"}}
              ({{this.data.market_health.stale.length}})</summary>{{#each
              this.data.market_health.stale
              as |item|
            }}<p>{{item.symbol}}
                ·
                {{item.error}}</p>{{/each}}</details>{{/if}}</section>
      <section class="rsc-card"><h2>{{uiText "campaign"}}</h2><p>{{uiText
            "campaign_hint"
          }}</p><button
          type="button"
          class="btn"
          {{on "click" this.campaignPreview}}
        >{{uiText "campaign_preview"}}</button>{{#if this.campaign}}<p>{{uiText
              "participants"
            }}:
            {{this.campaign.participants}}
            ·
            {{uiText "campaign_pending"}}:
            {{this.campaign.pending}}
            ·
            {{this.campaign.rebate_pending}}
            RSC</p><button
            type="button"
            class="btn btn-primary"
            disabled={{this.campaignDisabled}}
            {{on "click" this.campaignApply}}
          >{{uiText "campaign_apply"}}</button>{{/if}}</section>
      <div class="rsc-grid"><section class="rsc-card"><h2>{{uiText
              "wallet_lookup"
            }}</h2><form {{on "submit" this.search}}><label>{{uiText
                "username"
              }}<input
                value={{this.query}}
                {{on "input" this.queryChange}}
              /></label><button class="btn" type="submit">{{uiText
                "search"
              }}</button></form><div class="rsc-table"><table><tbody>{{#each
                  this.data.wallets
                  as |wallet|
                }}<tr><td>{{wallet.id}}</td><td><ForumUser @user={{wallet.forum_user}} @name={{wallet.username}} /></td><td
                    >{{formatAmount wallet.balance}} RSC</td><td
                    >{{wallet.status}}</td></tr>{{/each}}</tbody></table></div><RscPagination @page={{this.data.pagination.wallet}} @change={{fn this.pageChanged "wallet"}} /></section>
        <section class="rsc-card"><h2>{{uiText "admin_action"}}</h2><p
            class="rsc-muted"
          >{{uiText "admin_action_hint"}}</p><form
            {{on "submit" this.submit}}
          ><label>{{uiText "operation"}}<select
                aria-label={{uiText "operation"}}
                {{on "change" this.choose}}
              >{{#each operations as |operation|}}<option
                    value={{operation}}
                    selected={{eq this.operation operation}}
                  >{{uiText
                      operation
                    }}</option>{{/each}}</select></label>{{#each
              this.formFields
              as |field|
            }}<label>{{uiText field.key}}{{#if field.options}}<select
                    aria-label={{uiText field.key}}
                    {{on "change" (fn this.change field.key)}}
                  >{{#each field.options as |choice|}}<option
                        value={{choice}}
                        selected={{eq field.value choice}}
                      >{{choice}}</option>{{/each}}</select>{{else}}<input
                    required={{field.required}}
                    value={{field.value}}
                    {{on "input" (fn this.change field.key)}}
                  />{{/if}}</label>{{/each}}<button
              class="btn btn-primary"
              type="submit"
              disabled={{this.writeDisabled}}
            >{{uiText "save"}}</button></form></section></div>
      <section class="rsc-card"><h2>{{uiText "daily_rewards"}}</h2><label
        >{{uiText "date"}}<input
            type="date"
            value={{this.date}}
            {{on "input" this.dateChange}}
          /></label><button
          class="btn"
          disabled={{this.busy}}
          type="button"
          {{on "click" (fn this.preview false)}}
        >{{uiText "preview"}}</button><button
          class="btn"
          disabled={{this.writeDisabled}}
          type="button"
          {{on "click" (fn this.preview true)}}
        >{{uiText "pay_rewards"}}</button>{{#if this.rewards}}<p>共 {{this.rewards.length}} 人 · 待发放 {{this.pendingRewardAmount}} RSC</p><label>奖励状态<select aria-label="奖励状态" {{on "change" this.filterRewards}}><option value="all">全部</option><option value="pending">待发放</option><option value="paid">已发放</option><option value="frozen">钱包冻结</option></select></label><div class="rsc-table"><table><thead><tr><th>用户</th><th>奖励</th><th>状态</th></tr></thead><tbody>{{#each this.rewardRows as |row|}}<tr><td><ForumUser @user={{row.forum_user}} @name={{row.username}} /></td><td>{{row.score}} RSC</td><td>{{#if row.paid}}已发放{{else if row.frozen}}钱包冻结{{else}}待发放{{/if}}</td></tr>{{else}}<tr><td colspan="3">暂无符合条件的记录。</td></tr>{{/each}}</tbody></table></div><RscPagination @page={{this.rewardPagination}} @change={{this.changeRewardPage}} />{{/if}}</section>
      <RscAdminTools @readOnly={{this.data.read_only}} @requests={{this.data.requests}} @refresh={{this.refresh}} />
      <section class="rsc-card"><h2>{{uiText "data_sources"}}</h2><label>{{uiText "category"}}<select value={{this.instrumentCategory}} {{on "change" this.instrumentCategoryChanged}}><option value="">全部市场</option>{{#each options.category as |category|}}<option value={{category}}>{{categoryText category}}</option>{{/each}}</select></label><form {{on "submit" this.instrumentSearch}}><label>按标的代码或名称搜索<input value={{this.instrumentQuery}} {{on "input" this.instrumentQueryChanged}} /></label><button class="btn" type="submit">搜索</button></form><button
          class="btn"
          type="button"
          disabled={{this.writeDisabled}}
          {{on "click" this.sync}}
        >{{uiText "sync_now"}}</button><div class="rsc-table"><table><tbody
            >{{#each this.data.instruments as |item|}}<tr><td
                  >{{item.symbol}}</td><td>{{item.name}}</td><td
                  >{{item.provider}}</td><td>{{item.synced_at}}</td><td
                  >{{item.error}}</td></tr>{{/each}}</tbody></table></div><RscPagination @page={{this.data.pagination.instrument}} @change={{fn this.pageChanged "instrument"}} /></section>
      <section class="rsc-card"><h2>{{uiText "market_requests"}}</h2><div
          class="rsc-table"
        ><table><tbody>{{#each this.data.requests as |item|}}<tr><td
                  >#{{item.id}}</td><td>{{item.symbol}}</td><td
                  >{{item.status}}</td><td
                  >{{item.user_id}}{{#if item.details.metadata.requested_name}} · {{item.details.metadata.requested_name}}{{/if}}</td></tr>{{/each}}</tbody></table></div><RscPagination @page={{this.data.pagination.request}} @change={{fn this.pageChanged "request"}} /></section>
      <details class="rsc-card"><summary>{{uiText
            "settlement_review"
          }}</summary><pre>{{json this.data.matches}}</pre></details><details
        class="rsc-card"
      ><summary>{{uiText "notification_queue"}}</summary><pre>{{json
            this.data.events
          }}</pre></details>
      <details class="rsc-card"><summary>{{uiText
            "fund_activity"
          }}</summary><pre>{{json this.data.funds}}</pre><RscPagination @page={{this.data.pagination.fund}} @change={{fn this.pageChanged "fund"}} /></details>
      <section class="rsc-card"><h2>{{uiText "audit_log"}}</h2>{{#each
          this.data.audits
          as |audit|
        }}<details><summary>#{{audit.id}}
              ·
              {{audit.action}}
              ·
              {{audit.created_at}}</summary><pre>{{json
                audit.details
              }}</pre></details>{{/each}}<RscPagination @page={{this.data.pagination.audit}} @change={{fn this.pageChanged "audit"}} /></section>
    </main>
  </template>
}
