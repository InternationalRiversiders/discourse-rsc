import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import ForumUser from "./rsc-user";
import { signedAmount } from "../lib/rsc-format";
import { formatDateTime } from "../lib/campus-time";

export default class extends Component {
  @tracked period = "month";
  @tracked data = null;
  @tracked loading = false;
  @tracked error = "";
  request = 0;
  constructor() { super(...arguments); this.load(); }
  get streak() { return ["coin", "dice", "blackjack"].includes(this.args.game); }
  get title() { return this.streak ? "连胜榜" : this.args.game === "lottery" ? "单期净盈利榜" : "单局净盈利榜"; }
  get note() { return this.streak ? "按所选时段内最高连胜排名；平局、退款不计胜负。" : this.args.game === "lottery" ? "按单期全部奖金减去该期购票金额排名。" : "按所选时段内单局返还减去投入排名。"; }
  get rows() {
    return (this.data?.rows || []).map((row, i) => ({
      ...row, rank: i + 1, top: i < 3,
      valueLabel: this.streak ? `${row.value} 连胜` : `${signedAmount(row.value)} RSC`,
      time: formatDateTime(row.achieved_at),
    }));
  }
  @action async load() {
    const request = ++this.request;
    this.loading = true; this.error = "";
    try {
      const data = await ajax("/rsc/games/ranking.json", {data: {game: this.args.game, period: this.period}});
      if (!this.isDestroying && !this.isDestroyed && request === this.request) { this.data = data; }
    } catch (e) {
      if (!this.isDestroying && !this.isDestroyed && request === this.request) { this.error = extractError(e); }
    } finally {
      if (!this.isDestroying && !this.isDestroyed && request === this.request) { this.loading = false; }
    }
  }
  @action select(period) { if (this.period !== period) { this.period = period; this.data = null; this.load(); } }
  <template>
    <section class="rg-ranking" aria-label={{this.title}} aria-busy={{if this.loading "true" "false"}}>
      <header class="rg-ranking-heading"><h2>{{this.title}}</h2><div class="rg-ranking-period"><button type="button" class={{if (eq this.period "month") "is-selected"}} aria-pressed={{eq this.period "month"}} {{on "click" (fn this.select "month")}}>近30天</button><button type="button" class={{if (eq this.period "all") "is-selected"}} aria-pressed={{eq this.period "all"}} {{on "click" (fn this.select "all")}}>总榜</button><button type="button" title="刷新排行榜" aria-label="刷新排行榜" disabled={{this.loading}} {{on "click" this.load}}>{{dIcon "arrows-rotate"}}</button></div></header>
      <p class="rg-ranking-note">{{this.note}}每人保留最佳成绩，同分先达成者在前。</p>
      {{#if this.error}}<p class="rg-ranking-status" role="alert">{{this.error}} <button type="button" {{on "click" this.load}}>重试</button></p>
      {{else if this.loading}}<p class="rg-ranking-status" role="status">正在加载…</p>
      {{else if this.rows.length}}<ol class="rg-ranking-list">{{#each this.rows key="user.id" as |row|}}<li><span class="rg-ranking-place {{if row.top 'is-top'}}">{{row.rank}}</span><ForumUser @user={{row.user}} /><strong title={{row.time}}>{{row.valueLabel}}</strong></li>{{/each}}</ol>
      {{else}}<p class="rg-ranking-status">这个时段还没有上榜成绩</p>{{/if}}
    </section>
  </template>
}
