import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";

export default class RscTeam extends Component {
  @tracked failedUrl;

  get showLogo() {
    return this.args.logo && this.failedUrl !== this.args.logo;
  }

  get initials() {
    return Array.from(this.args.name || "").slice(0, 2).join("");
  }

  get translated() {
    return this.args.name !== this.args.original;
  }

  @action imageFailed(event) {
    this.failedUrl = event.target.getAttribute("src");
  }

  <template>
    <span class="rsc-team" title={{@original}}>
      <span class="rsc-team-symbol {{if @away 'away'}}" aria-hidden="true">
        {{#if this.showLogo}}
          <img class="rsc-team-logo" src={{@logo}} alt="" width="48" height="48"
            loading="lazy" decoding="async" referrerpolicy="no-referrer"
            {{on "error" this.imageFailed}} />
        {{else}}
          {{this.initials}}
        {{/if}}
      </span>
      <span class="rsc-team-name">{{@name}}{{#if this.translated}}<small>{{@original}}</small>{{/if}}</span>
    </span>
  </template>
}
