import Component from "@glimmer/component";
import { service } from "@ember/service";
import { LinkTo } from "@ember/routing";
import { i18n } from "discourse-i18n";
const uiText = (key) => i18n(`discourse_rsc.ui.${key}`);
export default class RscNavigation extends Component {
  @service currentUser;
  @service siteSettings;
  <template>
    <nav class="rsc-tabs" aria-label={{uiText "navigation"}}>
      {{#if this.currentUser.rsc_member}}
        <LinkTo @route="rsc.index">{{uiText "wallet"}}</LinkTo>
        <LinkTo @route="rsc.market">{{uiText "market"}}</LinkTo>
        <LinkTo @route="rsc.sports">{{uiText "sports"}}</LinkTo>
        {{#if this.siteSettings.rsc_forecast_enabled}}<LinkTo @route="rsc.forecast">{{uiText "forecast"}}</LinkTo>{{/if}}
        <LinkTo @route="rsc.leaderboard">{{uiText "leaderboard"}}</LinkTo>
      {{/if}}
      {{#if this.currentUser.rsc_admin}}
        <LinkTo @route="rsc.admin">{{uiText "administration"}}</LinkTo>
      {{/if}}
    </nav>
  </template>
}
