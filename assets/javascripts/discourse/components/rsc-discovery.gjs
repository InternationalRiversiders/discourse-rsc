import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
const uiText = (key) => i18n(`discourse_rsc.ui.${key}`);
export default class extends Component {
  @tracked query = "";
  @tracked results = [];
  @tracked notice = "";
  @tracked busy = false;
  @action change(event) {
    this.query = event.target.value;
  }
  @action async search(event) {
    event.preventDefault();
    this.busy = true;
    this.notice = "";
    try {
      this.results = (
        await ajax("/rsc/search.json", { type: "POST", data: { q: this.query } })
      ).candidates;
    } catch (error) {
      this.notice = extractError(error);
    } finally {
      this.busy = false;
    }
  }
  @action async request(symbol) {
    this.busy = true;
    try {
      await ajax("/rsc/market-requests.json", {
        type: "POST",
        data: { symbol },
      });
      this.notice = uiText("request_sent");
    } catch (error) {
      this.notice = extractError(error);
    } finally {
      this.busy = false;
    }
  }
  <template>
    <details class="rsc-card rsc-discovery"><summary>{{uiText
          "external_search"
        }}</summary><form {{on "submit" this.search}}><label>{{uiText
            "search_markets"
          }}<input
            minlength="2"
            maxlength="60"
            required
            value={{this.query}}
            {{on "input" this.change}}
          /></label><button
          class="btn"
          type="submit"
          disabled={{this.busy}}
        >{{uiText "search"}}</button></form>{{#if this.notice}}<p
          role="status"
        >{{this.notice}}</p>{{/if}}{{#each this.results as |item|}}<div
          class="rsc-discovery-row"
        ><span><strong>{{item.symbol}}</strong>
            ·
            {{item.name}}
            <small>{{item.exchange}}</small></span><button
            class="btn btn-small"
            disabled={{this.busy}}
            type="button"
            {{on "click" (fn this.request item.symbol)}}
          >{{uiText "request_market"}}</button></div>{{/each}}</details>
  </template>
}
