import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";

export default class extends Component {
  @tracked draft = null;
  @tracked baseVersion = null;
  @tracked busy = false;
  @tracked error = "";
  @tracked success = "";
  get rows() {
    const plan = this.args.plan || {};
    return (this.draft ?? plan.selections ?? []).map((row, index) => {
      const result = (plan.last_result?.rows || []).find(r => r.number === row.number);
      const current = plan.last_result?.draw_id === this.args.drawId;
      const resultLabel = result ? `${current ? '本期' : '上期'}${result.status === 'bought' ? `已购 ${result.quantity} 注` : `跳过：${result.reason}`}` : "";
      return { ...row, index, key: row.key || `saved-${index}`, resultLabel };
    });
  }
  get count() { return this.rows.filter(r => r.enabled).reduce((n,r) => n + (Number(r.quantity) || 0), 0); }
  get cost() { return this.count * 5; }
  get canAdd() { return !this.busy && this.rows.length < 20; }
  get dirty() { return this.draft !== null; }
  get validation() {
    if (this.count > 20) { return "启用号码的每日总注数不能超过 20 注。"; }
    const filled = this.rows.filter(r => r.number.length === 4);
    return new Set(filled.map(r => r.number)).size !== filled.length ? "同一号码请合并注数，不要重复添加。" : "";
  }
  get scheduled() { return this.draft === null && this.active && Date.parse(this.args.plan?.effective_at) <= Date.now(); }
  get invalid() {
    const rows = this.rows;
    return this.busy || this.args.readOnly || this.draft === null || this.count > 20 ||
      rows.some(r => !/^\d{4}$/.test(r.number) || !Number.isInteger(Number(r.quantity)) || Number(r.quantity) < 1 || Number(r.quantity) > 20) ||
      new Set(rows.map(r => r.number)).size !== rows.length;
  }
  get nextStart() {
    const at = this.draft === null && this.args.plan?.effective_at ? this.args.plan.effective_at : this.args.drawAt;
    return at ? new Intl.DateTimeFormat('zh-CN', { timeZone:'Asia/Shanghai', month:'numeric', day:'numeric', hour:'2-digit', minute:'2-digit', hour12:false }).format(new Date(at)) : '下一期';
  }
  get active() { return (this.args.plan?.selections || []).some(r => r.enabled); }
  edit(rows) {
    if (this.draft === null) { this.baseVersion = this.args.plan?.version || 0; }
    this.draft = rows; this.error = ''; this.success = '';
  }
  @action add() { if (this.canAdd) { this.edit([...this.rows, { number:'', quantity:1, enabled:true, key:crypto.randomUUID() }]); } }
  @action remove(index) { this.edit(this.rows.filter((r,i) => i !== index)); }
  @action change(index, field, event) {
    let value = field === 'enabled' ? event.target.checked : event.target.value;
    if (field === 'number') { value = value.replace(/\D/g,'').slice(0,4); event.target.value = value; }
    this.edit(this.rows.map((r,i) => i === index ? { ...r, [field]:value } : r));
  }
  @action cancel() { this.draft = null; this.baseVersion = null; this.error = ''; this.success = ''; }
  @action async save(event) {
    event.preventDefault(); if (this.invalid) { return; }
    this.busy = true; this.error = ''; this.success = '';
    try {
      const plan = await ajax('/rsc/lottery/auto-plan.json', { type:'PUT', contentType:'application/json', data:JSON.stringify({ version:this.baseVersion,
        selections:this.rows.map(r => ({ number:r.number, quantity:Number(r.quantity), enabled:r.enabled })) }) });
      if (this.isDestroying || this.isDestroyed) { return; }
      this.args.onSaved(plan); this.draft = null; this.baseVersion = null;
      this.success = plan.selections.some(r => r.enabled) ? '计划已保存，从下一期开售后自动购票。' : '自动投注已暂停，已购的彩票保留。';
    } catch (e) {
      if (!this.isDestroying && !this.isDestroyed) { this.error = extractError(e); }
    } finally { if (!this.isDestroying && !this.isDestroyed) { this.busy = false; } }
  }
  <template>
    <section class="rl-auto" aria-label="每日自动投注">
      <div class="rl-auto-heading"><div><span class="rl-auto-eyebrow">每日计划</span><h2>自动投注</h2></div><button type="button" disabled={{unless this.canAdd true}} {{on "click" this.add}}>＋ 添加号码</button></div>
      <form {{on "submit" this.save}}>
        <div class="rl-auto-list">
          {{#each this.rows key="key" as |row|}}
            <div class="rl-auto-row {{unless row.enabled 'is-paused'}}">
              <label class="rl-auto-number">号码<input type="text" inputmode="numeric" autocomplete="off" maxlength="4" placeholder="0000" value={{row.number}} disabled={{this.busy}} {{on "input" (fn this.change row.index "number")}} /></label>
              <label class="rl-auto-quantity">每日注数<input type="number" min="1" max="20" step="1" value={{row.quantity}} disabled={{this.busy}} {{on "input" (fn this.change row.index "quantity")}} /></label>
              <label class="rl-auto-toggle"><input type="checkbox" checked={{row.enabled}} disabled={{this.busy}} {{on "change" (fn this.change row.index "enabled")}} /><span>{{if row.enabled "启用" "暂停"}}</span></label>
              <button class="rl-auto-remove" type="button" disabled={{this.busy}} aria-label="移除这个号码" {{on "click" (fn this.remove row.index)}}>移除</button>
              {{#if row.resultLabel}}<small class="rl-auto-result">{{row.resultLabel}}</small>{{/if}}
            </div>
          {{else}}<div class="rl-auto-empty">添加常用号码，每天自动购票。</div>{{/each}}
        </div>
        <div class="rl-auto-footer"><div class="rl-auto-total"><span>每天 {{this.count}} / 20 注</span><strong>{{this.cost}} <small>RSC / 天</small></strong></div><div class="rl-auto-actions">{{#if this.dirty}}<button type="button" disabled={{this.busy}} {{on "click" this.cancel}}>取消修改</button>{{/if}}<button type="submit" class="rl-auto-save" disabled={{this.invalid}}>{{#if this.busy}}保存中…{{else if this.count}}{{if this.active "保存计划" "开启自动投注"}}{{else}}暂停自动投注{{/if}}</button></div></div>
        {{#if this.validation}}<p class="rl-error" role="alert">{{this.validation}}</p>{{/if}}
        {{#if this.error}}<p class="rl-error" role="alert">{{this.error}}</p>{{/if}}
        {{#if this.success}}<p class="rl-success" role="status">{{this.success}}</p>{{/if}}
        <p class="rl-hint">{{#if this.scheduled}}每期开售后自动购票。{{else}}保存后从 {{this.nextStart}}（北京时间）开售的新一期生效。{{/if}}每天自动扣除 {{this.cost}} RSC，直到暂停或移除。余额或本期剩余注数不足时，按列表顺序跳过无法购买的号码，不补买；与手动购票合计每期最多 20 注。</p>
      </form>
    </section>
  </template>
}
