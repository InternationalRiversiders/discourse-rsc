import RscGameRanking from "./rsc-game-ranking";
import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { service } from "@ember/service";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { modifier } from "ember-modifier";
import { LinkTo } from "@ember/routing";
import { eq } from "truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";

const money = (value) => Number(value || 0).toLocaleString("zh-CN", { maximumFractionDigits: 2 });
const deadline = (value) => value ? new Intl.DateTimeFormat("zh-CN", { timeZone: "Asia/Shanghai", month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(value)) : "—";
export default class extends Component {
  @service currentUser;
  @tracked data = this.args.model;
  @tracked number = "";
  @tracked quantity = "1";
  @tracked busy = false;
  @tracked loading = false;
  @tracked error = "";
  @tracked success = "";
  @tracked pending = null;
  @tracked now = Date.now();
  @tracked tab = "mine";
  constructor() {
    super(...arguments);
    try {
      const saved = JSON.parse(sessionStorage.getItem(this.storageKey));
      if (saved?.request_id && /^\d{4}$/.test(saved.number) && Number.isInteger(saved.quantity) && saved.quantity >= 1 && saved.quantity <= 20) {
        this.pending = saved;
        this.number = saved.number;
        this.quantity = String(saved.quantity);
      }
    } catch { /* Storage can be unavailable in private browsing. */ }
  }
  get storageKey() { return `rsc-lottery-pending:${this.currentUser.id}`; }
  get current() { return this.data.current; }
  get pool() { return money(this.current?.pool); }
  get balance() { return money(this.data.balance); }
  get remaining() { return Math.max(0, this.data.limit - (this.current?.mine || 0)); }
  get total() { return money(Number(this.quantity) * this.data.price); }
  get drawDate() { return deadline(this.current?.draw_at); }
  get closed() { return !this.current || Date.parse(this.current.draw_at) <= this.now; }
  get countdown() {
    const seconds = Math.max(0, Math.floor((Date.parse(this.current?.draw_at) - this.now) / 1000));
    if (!Number.isFinite(seconds) || this.closed) { return "开奖中"; }
    return [Math.floor(seconds / 3600), Math.floor(seconds / 60) % 60, seconds % 60].map(n => String(n).padStart(2, "0")).join(":");
  }
  get locked() { return this.busy || !!this.pending; }
  get disabled() {
    if (this.pending) { return this.busy || this.data.read_only || this.data.wallet_status !== "active"; }
    const n = Number(this.quantity);
    return this.busy || this.closed || this.data.read_only || this.data.wallet_status !== "active" ||
      !/^\d{4}$/.test(this.number) || !Number.isInteger(n) || n < 1 || n > this.remaining || n * this.data.price > Number(this.data.balance);
  }
  get notice() {
    if (this.data.read_only) { return "维护中，暂不可购票。"; }
    if (this.data.wallet_status !== "active") { return "钱包当前不可用于购票。"; }
    if (!this.remaining) { return "本期已购满 20 注，祝你好运。"; }
    if (this.closed) { return "本期已截止，正在等待开奖。"; }
    return "";
  }
  get tickets() {
    return (this.data.mine || []).map(t => ({ ...t, date: deadline(t.draw_at), payoutLabel: money(t.payout),
      state: !t.settled ? "待开奖" : t.matches === 4 ? "一等奖" : t.matches === 3 ? "二等奖" : t.matches === 2 ? "三等奖" : "未中奖",
      winning: t.settled && t.matches >= 2 }));
  }
  get history() {
    return (this.data.history || []).map(d => ({ ...d, date: deadline(d.draw_at), digits: d.number.split("").map((value, index) => ({ value, index })), paidLabel: money(d.paid) }));
  }
  get latest() { return this.history[0]; }
  get stats() {
    const a = this.data.accounting;
    return a ? [["购票总额", a.revenue], ["手续费回收", a.fees], ["系统累计补贴", a.subsidies], ["小奖派奖", a.small_prizes], ["头奖派奖", a.jackpots], ["现存奖池", a.pool], ["净回收", a.net_recovered]].map(([label, value]) => ({ label, value: money(value) })) : [];
  }
  clock = modifier(() => {
    let ticks = 0;
    const timer = setInterval(() => {
      this.now = Date.now();
      if (++ticks % 30 === 0 && !document.hidden) { this.refresh(true); }
    }, 1000);
    return () => clearInterval(timer);
  });
  @action setNumber(event) { this.number = event.target.value.replace(/\D/g, "").slice(0, 4); event.target.value = this.number; this.success = ""; }
  @action setQuantity(event) { this.quantity = event.target.value; this.success = ""; }
  @action randomize() {
    const values = [];
    while (values.length < 4) { const n = crypto.getRandomValues(new Uint8Array(1))[0]; if (n < 250) { values.push(n % 10); } }
    this.number = values.join(""); this.success = "";
  }
  @action showMine() { this.tab = "mine"; }
  @action showHistory() { this.tab = "history"; }
  savePending(value) {
    this.pending = value;
    try { if (value) { sessionStorage.setItem(this.storageKey, JSON.stringify(value)); } else { sessionStorage.removeItem(this.storageKey); } } catch { /* Retry still works in this page. */ }
  }
  @action async refresh(quiet = false) {
    if (this.loading || this.busy) { return; }
    this.loading = true;
    try { const data = await ajax("/rsc/lottery/state.json"); if (!this.isDestroying && !this.isDestroyed) { this.data = data; this.now = Date.now(); } }
    catch (e) { if (quiet !== true && !this.isDestroying && !this.isDestroyed) { this.error = extractError(e); } }
    finally { if (!this.isDestroying && !this.isDestroyed) { this.loading = false; } }
  }
  @action async buy(event) {
    event.preventDefault();
    if (this.disabled) { return; }
    this.error = ""; this.success = ""; this.busy = true;
    if (!this.pending) { this.savePending({ draw_id: this.current.id, number: this.number, quantity: Number(this.quantity), request_id: crypto.randomUUID() }); }
    try {
      const result = await ajax("/rsc/lottery/buy.json", { type: "POST", data: this.pending });
      if (this.isDestroying || this.isDestroyed) { return; }
      this.savePending(null);
      this.data = { ...this.data, balance: result.balance };
      this.success = `已购 ${result.ticket.number} × ${result.ticket.quantity} 注，${deadline(result.ticket.draw_at)} 开奖（北京时间）。`;
    } catch (e) {
      if (this.isDestroying || this.isDestroyed) { return; }
      const status = e.jqXHR?.status || e.status;
      const definitive = status >= 400 && status < 500 && ![408, 429].includes(status);
      this.error = extractError(e);
      if (definitive) { this.savePending(null); }
      else { this.error = "暂未确认购票结果，请重试同一笔，不会重复扣款。"; }
    } finally {
      if (!this.isDestroying && !this.isDestroyed) { this.busy = false; await this.refresh(true); }
    }
  }
  <template>
    <section class="rl-page" aria-label="Riverside 大乐透" {{this.clock}}>
      <div class="rl-toolbar"><LinkTo @route="rsc-games">← 返回游戏</LinkTo><span>可用余额 <strong>{{this.balance}} RSC</strong></span><button type="button" disabled={{this.loading}} {{on "click" this.refresh}}>刷新</button></div>
      <header class="rl-hero">
        <div><span class="rl-kicker">RIVERSIDE</span><h1>大乐透</h1><p>每日 20:00 开奖 · 北京时间</p></div>
        <div class="rl-pool"><span>当前奖池</span><strong>{{this.pool}} <small>RSC</small></strong><span>{{this.drawDate}} · {{this.countdown}}</span></div>
      </header>
      <div class="rl-layout">
        <form class="rl-pick" {{on "submit" this.buy}}>
          <div class="rl-heading"><h2>选个好号码</h2><button type="button" disabled={{this.locked}} {{on "click" this.randomize}}>随机选号 ↻</button></div>
          <label for="rl-number">四位数字 · 0000–9999</label>
          <input id="rl-number" class="rl-number" type="text" inputmode="numeric" autocomplete="off" maxlength="4" placeholder="0000" value={{this.number}} disabled={{this.locked}} {{on "input" this.setNumber}} />
          <div class="rl-buy-row"><label for="rl-quantity">注数 <input id="rl-quantity" type="number" min="1" max={{this.remaining}} step="1" value={{this.quantity}} disabled={{this.locked}} {{on "input" this.setQuantity}} /></label><span>每注 5 RSC<br />本期已购 {{this.current.mine}} / 20 注</span></div>
          {{#if this.notice}}<p class="rl-notice">{{this.notice}}</p>{{/if}}
          {{#if this.error}}<p class="rl-error" role="alert">{{this.error}}</p>{{/if}}
          {{#if this.success}}<p class="rl-success" role="status">{{this.success}}</p>{{/if}}
          <button type="submit" class="rl-submit" disabled={{this.disabled}}>{{#if this.busy}}正在确认…{{else if this.pending}}确认同一笔购票{{else}}确认购买 · {{this.total}} RSC{{/if}}</button>
          <p class="rl-hint">同一号码可买多注，成功购票后不可撤回。</p>
        </form>
        <section class="rl-prizes" aria-label="中奖规则">
          <h2>对上几位，就看这一期</h2>
          <div class="rl-prize"><span><b>4 位全中</b><small>一等奖</small></span><strong>瓜分头奖</strong></div>
          <div class="rl-prize"><span><b>恰好中 3 位</b><small>二等奖</small></span><strong>100 <small>RSC / 注</small></strong></div>
          <div class="rl-prize"><span><b>恰好中 2 位</b><small>三等奖</small></span><strong>10 <small>RSC / 注</small></strong></div>
          <p class="rl-hint">数字与位置均相同才算命中，各奖项不叠加。</p>
          {{#if this.latest}}<div class="rl-last"><span>上期开奖号码 · {{this.latest.date}}</span><div class="rl-balls">{{#each this.latest.digits key="index" as |digit|}}<b>{{digit.value}}</b>{{/each}}</div></div>{{/if}}
        </section>
      </div>
      <section class="rl-records">
        <nav class="rl-tabs" aria-label="彩票记录"><button type="button" class={{if (eq this.tab "mine") "active"}} {{on "click" this.showMine}}>我的彩票</button><button type="button" class={{if (eq this.tab "history") "active"}} {{on "click" this.showHistory}}>往期开奖</button></nav>
        {{#if (eq this.tab "mine")}}<div class="rl-ticket-list">{{#each this.tickets key="id" as |ticket|}}<article class="rl-ticket {{if ticket.winning 'winning'}}"><div><strong>{{ticket.number}}</strong><span>× {{ticket.quantity}} 注</span><small>{{ticket.date}} 开奖</small></div><div><b>{{ticket.state}}</b>{{#if ticket.winning}}<span>+{{ticket.payoutLabel}} RSC</span>{{/if}}</div></article>{{else}}<p class="rl-empty">还没有彩票，选一个属于你的号码。</p>{{/each}}</div>
        {{else}}<div class="rl-draw-list">{{#each this.history key="id" as |draw|}}<article class="rl-draw"><span>{{draw.date}}</span><div class="rl-balls">{{#each draw.digits key="index" as |digit|}}<b>{{digit.value}}</b>{{/each}}</div><span>头奖 {{draw.winners}} 注 · 派奖 {{draw.paidLabel}} RSC</span></article>{{else}}<p class="rl-empty">等待第一期开奖。</p>{{/each}}</div>{{/if}}
      </section>
      <RscGameRanking @game="lottery" />
      <details class="rl-rules"><summary>玩法与奖池规则</summary><p>每天北京时间 20:00 截止并开奖，四位数字独立随机产生，可包含 0，也可重复。每人每期最多 20 注。</p><p>每注 5 RSC，其中 4 RSC 进入奖池，1 RSC 由系统回收。先支付二、三等奖，再由一等奖按中奖注数平分剩余奖池。小奖总额超过奖池时按比例分配，不额外增发。</p><p>初始奖池投入 5,000 RSC；无人中一等奖时余额滚入下一期，有人中一等奖后下一期补入 3,000 RSC。奖金为返还总额，包含本金；不可分割的极小尾数留在奖池。此处仅使用社区娱乐积分。</p></details>
      {{#if this.data.accounting}}<details class="rl-rules rl-accounting"><summary>奖池账目 · 管理员</summary><div class="rl-stats">{{#each this.stats as |stat|}}<div><span>{{stat.label}}</span><strong>{{stat.value}} RSC</strong></div>{{/each}}</div><p>净回收 = 手续费回收 − 系统累计补贴；现存奖池仍用于派奖，不计作永久回收。</p></details>{{/if}}
    </section>
  </template>
}
