import Component from "@glimmer/component";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
export default class extends Component {
  get first() { return !this.args.page || this.args.page.page <= 1; }
  get last() { return !this.args.page || this.args.page.page >= this.args.page.pages; }
  @action previous() { return this.args.change(this.args.page.page - 1); }
  @action next() { return this.args.change(this.args.page.page + 1); }
  <template>
    <div class="rsc-list-footer"><span>共 {{@page.total}} 条 · {{@page.page}} / {{@page.pages}}</span><div><button type="button" class="btn btn-small" disabled={{this.first}} {{on "click" this.previous}}>上一页</button><button type="button" class="btn btn-small" disabled={{this.last}} {{on "click" this.next}}>下一页</button></div></div>
  </template>
}
