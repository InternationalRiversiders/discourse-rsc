import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { formatDateTime } from "../lib/campus-time";
import { formatPrice } from "../lib/rsc-format";
const statusText = (status) => ({ draft: "待确认", approved: "已安排", canceled: "已取消", applied: "已计入仓位" })[status] || status;
export default class RscDividendsAdmin extends Component {
  @tracked data;
  @tracked draft = {};
  @tracked busy = false;
  @tracked error = "";
  requests = new Map();
  @action change(key, event) { this.draft = { ...this.draft, [key]: event.target.value }; }
  @action async load(event) {
    if (event && !event.target.open) { return; }
    if (this.busy) { return; }
    this.busy = true;
    try { this.data = await ajax("/rsc/admin/dividends.json"); this.error = ""; }
    catch (error) { this.error = extractError(error); }
    finally { this.busy = false; }
  }
  async post(path, data) {
    if (this.busy) { return; }
    this.busy = true;
    this.error = "";
    const key = JSON.stringify([path, data]);
    const requestId = this.requests.get(key) || crypto.randomUUID();
    this.requests.set(key, requestId);
    try {
      await ajax(path, { type: "POST", data: { ...data, request_id: requestId } });
      this.requests.delete(key);
      this.data = await ajax("/rsc/admin/dividends.json");
      return true;
    } catch (error) { this.error = extractError(error); }
    finally { this.busy = false; }
  }
  @action async create(event) {
    event.preventDefault();
    if (await this.post("/rsc/admin/dividends.json", this.draft)) { this.draft = {}; }
  }
  @action review(item, decision) {
    return this.post(`/rsc/admin/dividends/${item.id}/review.json`, { decision, version: item.version });
  }
  <template>
    <details class="rsc-card rsc-dividends-admin" {{on "toggle" this.load}}>
      <summary>现金分红 · 试运行</summary>
      <p>仅支持美元美股现金分红。先依据发行方公告登记，再确认执行；不补发历史分红。除息后多头增加、空头扣减仓位权益，平仓时结算到钱包。</p>
      <p>除息时会撤销该品种的待成交委托，并按每股分红下调止盈、止损价格。拆股、送股及特殊除息规则暂不支持。</p>
      {{#if this.error}}<div class="alert alert-error" role="alert">{{this.error}}</div>{{/if}}
      {{#if this.data}}
        {{#if this.data.enabled}}
          <form class="rsc-dividend-form" {{on "submit" this.create}}>
            <label>完整品种代码<input required placeholder="例如 AAPL（与市场代码一致）" value={{this.draft.symbol}} {{on "input" (fn this.change "symbol")}} /></label>
            <label>美国交易所除息日<input required type="date" value={{this.draft.ex_date}} {{on "input" (fn this.change "ex_date")}} /></label>
            <label>每股现金分红（USD）<input required inputmode="decimal" value={{this.draft.amount}} {{on "input" (fn this.change "amount")}} /></label>
            <label>发行方公告链接<input required type="url" placeholder="https://" value={{this.draft.source_url}} {{on "input" (fn this.change "source_url")}} /></label>
            <label class="rsc-dividend-form__reason">核对说明<input required maxlength="500" value={{this.draft.reason}} {{on "input" (fn this.change "reason")}} /></label>
            <button type="submit" class="btn btn-primary" disabled={{this.busy}}>保存待确认</button>
          </form>
          <p class="rsc-muted">按除息日纽约时间 09:30 的持仓确定资格；1 USD 分红折合 1 RSC。只登记普通现金分红，税费暂不模拟。</p>
        {{else}}<p class="rsc-muted">尚未开放新计划。管理员可在站点设置开启 rsc_dividends_enabled；已确认计划仍会执行。</p>{{/if}}
        <div class="rsc-scroll"><table class="rsc-compact-table"><thead><tr><th>品种 / 除息日</th><th>每股分红</th><th>来源 / 说明</th><th>状态</th><th>操作</th></tr></thead><tbody>
          {{#each this.data.rows key="id" as |item|}}<tr><td>{{item.symbol}}<small>{{item.ex_date}} · {{formatDateTime item.effective_at}}</small></td><td>{{formatPrice item.amount}} USD</td><td><a href={{item.source_url}} target="_blank" rel="noopener noreferrer">公告来源</a><small>{{item.reason}}</small></td><td>{{statusText item.status}}</td><td>
            {{#if (eq item.status "draft")}}{{#if this.data.enabled}}<button type="button" class="btn btn-small" disabled={{this.busy}} {{on "click" (fn this.review item "approved")}}>确认执行</button>{{/if}}{{/if}}
            {{#if (eq item.status "draft")}}<button type="button" class="btn btn-small" disabled={{this.busy}} {{on "click" (fn this.review item "canceled")}}>取消</button>{{else if (eq item.status "approved")}}<button type="button" class="btn btn-small" disabled={{this.busy}} {{on "click" (fn this.review item "canceled")}}>取消计划</button>{{/if}}
          </td></tr>{{else}}<tr><td colspan="5">暂无分红计划</td></tr>{{/each}}
        </tbody></table></div>
      {{/if}}
    </details>
  </template>
}
