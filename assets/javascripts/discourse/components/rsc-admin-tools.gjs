import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "discourse/truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { formatAmount } from "../lib/rsc-format";
import RscPagination from "./rsc-pagination";
const when = (value) => value ? new Date(value).toLocaleString() : "—";
const kinds = [{value:"all",label:"全部"},{value:"transfer",label:"转账"},{value:"post_tip",label:"帖子打赏"},{value:"red_packet",label:"红包"},{value:"issuance",label:"发行"},{value:"admin_adjustment",label:"资产调整"}];
const states = ["all","success","failed","pending","open","exhausted","closed","expired"];
export default class extends Component {
  @tracked query = "";
  @tracked kind = "all";
  @tracked status = "all";
  @tracked topicId = "";
  @tracked activity;
  @tracked demand;
  @tracked lookup = "";
  @tracked candidates = [];
  @tracked reason = "";
  @tracked busy = false;
  @tracked error = "";
  @tracked notice = "";
  requests = new Map();
  get writeDisabled() { return this.busy || this.args.readOnly; }
  @action change(key,event) { this[key] = event.target.value; }
  @action async load(page = 1,event) {
    event?.preventDefault();
    this.error = "";
    try { this.activity = await ajax("/rsc/admin/activity.json",{data:{kind:this.kind,q:this.query,status:this.status,topic_id:this.topicId,page}}); }
    catch(error) { this.error = extractError(error); }
  }
  @action async searches(page = 1) {
    try { this.demand = await ajax("/rsc/admin/search-demand.json",{data:{page}}); }
    catch(error) { this.error = extractError(error); }
  }
  @action async find(event) {
    event.preventDefault();this.error="";this.busy=true;
    try { this.candidates=(await ajax("/rsc/admin/market-lookup.json",{data:{q:this.lookup}})).candidates; }
    catch(error) { this.error=extractError(error); }
    finally { this.busy=false; }
  }
  async write(path,data) {
    if(this.writeDisabled) { return; }
    const key=JSON.stringify([path,data]);const id=this.requests.get(key)||crypto.randomUUID();this.requests.set(key,id);
    this.busy=true;this.error="";this.notice="";
    try { const result=await ajax(`/rsc/admin/${path}.json`,{type:"POST",data:{...data,request_id:id}});this.requests.delete(key);await this.args.refresh();return result; }
    catch(error) { this.error=extractError(error); }
    finally { this.busy=false; }
  }
  @action async approve(symbol) {
    if(!this.reason.trim()) { this.error="请先填写审批原因。";return; }
    const result=await this.write("market-approve",{symbol,reason:this.reason});
    if(result) { this.notice=`已收录 ${symbol}，对应申请已通过。`; }
  }
  @action async reject(id) {
    if(!this.reason.trim()) { this.error="请先填写审批原因。";return; }
    const result=await this.write("action",{operation:"reject_request",input:{id,reason:this.reason}});
    if(result) { this.notice="申请已拒绝，原因已写入审计。"; }
  }
  @action async settle() {
    const result=await this.write("settle",{});
    if(result) { this.notice=`已结算 ${result.settled} 笔预测，${result.failed} 场需要检查；未到确认时间的赛果继续等待。`; }
  }
  <template>
    <section class="rsc-card rsc-admin-tools">
      <h2>资金记录与帖子打赏</h2><p class="rsc-muted">同时查询迁移前后的记录。可按用户名、用户 ID 或话题筛选。</p>
      {{#if this.error}}<p class="alert alert-error" role="alert">{{this.error}}</p>{{/if}}
      {{#if this.notice}}<p class="alert alert-success" role="status">{{this.notice}}</p>{{/if}}
      <form class="rsc-fields" {{on "submit" (fn this.load 1)}}>
        <label>资金类型<select aria-label="资金类型" {{on "change" (fn this.change "kind")}}>{{#each kinds as |item|}}<option value={{item.value}} selected={{eq this.kind item.value}}>{{item.label}}</option>{{/each}}</select></label>
        <label>状态<select aria-label="状态" {{on "change" (fn this.change "status")}}>{{#each states as |item|}}<option value={{item}} selected={{eq this.status item}}>{{item}}</option>{{/each}}</select></label>
        <label>用户查询<input value={{this.query}} maxlength="80" {{on "input" (fn this.change "query")}} /></label>
        <label>话题 ID<input value={{this.topicId}} inputmode="numeric" {{on "input" (fn this.change "topicId")}} /></label>
        <button class="btn" type="submit">查询资金记录</button>
      </form>
      {{#if this.activity}}<div class="rsc-table"><table><thead><tr><th>时间</th><th>来源 / 类型</th><th>发起人</th><th>接收人</th><th>金额</th><th>状态 / 详情</th></tr></thead><tbody>
        {{#each this.activity.rows as |row|}}<tr><td>{{when row.created_at}}</td><td>{{row.origin}} · {{row.kind}}</td><td>{{row.sender}}</td><td>{{row.recipient}}</td><td>{{formatAmount row.amount}} RSC</td><td>{{row.status}} {{row.detail}}
        {{#if row.token}}<details><summary>红包领取详情</summary><p>已领取 {{row.packet.claimed_count}} / {{row.packet.count}} · 剩余 {{formatAmount row.packet.remaining}} RSC</p>{{#each row.claims as |claim|}}<p>#{{claim.user_id}} · {{formatAmount claim.amount}} RSC · {{when claim.at}}</p>{{/each}}</details>{{/if}}
        {{#if row.topic_id}}<p>话题 #{{row.topic_id}} · 帖子 #{{row.post_id}}</p>{{/if}}</td></tr>{{else}}<tr><td colspan="6">没有符合条件的记录。</td></tr>{{/each}}
      </tbody></table></div><RscPagination @page={{this.activity.pagination}} @change={{this.load}} />{{/if}}
    </section>
    <section class="rsc-card rsc-admin-approval">{{#if this.error}}<p class="alert alert-error" role="alert">{{this.error}}</p>{{/if}}{{#if this.notice}}<p class="alert alert-success" role="status">{{this.notice}}</p>{{/if}}<h2>标的搜索与申请审批</h2>
      <form class="rsc-fields" {{on "submit" this.find}}><label>外部代码或名称<input required minlength="2" maxlength="60" value={{this.lookup}} {{on "input" (fn this.change "lookup")}} /></label><button type="submit" class="btn" disabled={{this.busy}}>搜索外部标的</button></form>
      <label>审批原因<input maxlength="500" value={{this.reason}} {{on "input" (fn this.change "reason")}} /></label>
      {{#each this.candidates as |item|}}<p>{{item.symbol}} · {{item.name}} · {{item.exchange}} <button type="button" class="btn btn-small" disabled={{this.writeDisabled}} {{on "click" (fn this.approve item.symbol)}}>确认收录</button></p>{{/each}}
      {{#each @requests as |item|}}{{#if (eq item.status "pending")}}<p>#{{item.id}} · {{item.symbol}} · 用户 #{{item.user_id}} · 请求 {{item.details.request_count}} 次 <button type="button" class="btn btn-small" disabled={{this.writeDisabled}} {{on "click" (fn this.approve item.symbol)}}>通过申请</button> <button type="button" class="btn btn-small" disabled={{this.writeDisabled}} {{on "click" (fn this.reject item.id)}}>拒绝</button></p>{{/if}}{{/each}}
      <button type="button" class="btn" {{on "click" (fn this.searches 1)}}>查看搜索需求统计</button>
      {{#if this.demand}}<div class="rsc-table"><table><thead><tr><th>搜索词</th><th>次数</th><th>用户数</th><th>无结果</th><th>最近搜索</th></tr></thead><tbody>{{#each this.demand.rows as |row|}}<tr><td>{{row.query}}</td><td>{{row.count}}</td><td>{{row.users}}</td><td>{{row.empty_results}}</td><td>{{when row.last_at}}</td></tr>{{else}}<tr><td colspan="5">暂无搜索记录。</td></tr>{{/each}}</tbody></table></div><RscPagination @page={{this.demand.pagination}} @change={{this.searches}} />{{/if}}
    </section>
    <section class="rsc-card"><h2>赛事结算</h2><p>处理已经确认且达到等待时间的赛果；重复执行不会重复付款。</p><button type="button" class="btn" disabled={{this.writeDisabled}} {{on "click" this.settle}}>立即检查并结算</button></section>
  </template>
}
