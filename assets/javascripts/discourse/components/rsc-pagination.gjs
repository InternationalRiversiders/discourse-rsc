import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
export default class extends Component {
  @tracked target = "";
  @tracked targetFor;
  get signature() { const p=this.args.page; return JSON.stringify([p?.page,p?.pages,p?.total,p?.scope]); }
  get value() { return this.targetFor === this.signature ? this.target : ""; }
  get first() { return this.args.busy || !this.args.page || this.args.page.page <= 1; }
  get last() { return this.args.busy || !this.args.page || this.args.page.page >= this.args.page.pages; }
  get multiple() { return this.args.page?.pages > 1; }
  @action previous() { this.target = ""; return this.args.change(this.args.page.page - 1); }
  @action next() { this.target = ""; return this.args.change(this.args.page.page + 1); }
  @action input(event) { this.target = event.target.value; this.targetFor = this.signature; }
  @action jump(event) {
    event.preventDefault();
    const page = Number(this.value);
    if (this.args.busy || !Number.isInteger(page) || page < 1 || page > this.args.page.pages) { return; }
    this.target = "";
    return this.args.change(page);
  }
  <template>
    <div class="rsc-list-footer rsc-pagination"><span>共 {{@page.total}} 条 · {{@page.page}} / {{@page.pages}}</span><div class="rsc-page-buttons"><button type="button" class="btn btn-small" disabled={{this.first}} {{on "click" this.previous}}>上一页</button><button type="button" class="btn btn-small" disabled={{this.last}} {{on "click" this.next}}>下一页</button></div>{{#if this.multiple}}<form class="rsc-page-jump" {{on "submit" this.jump}}><label>直达<input aria-label="目标页码" required type="number" inputmode="numeric" min="1" max={{@page.pages}} step="1" value={{this.value}} {{on "input" this.input}} /></label><button type="submit" class="btn btn-small" disabled={{@busy}}>跳转</button></form>{{/if}}</div>
  </template>
}
