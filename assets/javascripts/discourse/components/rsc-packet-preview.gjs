import Component from "@glimmer/component";
import { service } from "@ember/service";
import { LinkTo } from "@ember/routing";
import { formatAmount } from "../lib/rsc-format";
import { i18n } from "discourse-i18n";
const text = (key) => i18n(`discourse_rsc.ui.${key}`);
export default class extends Component {
  @service currentUser;
  <template>
    <main class="rsc-app rsc-public-packet"><section class="rsc-card rsc-packet">
      <p>{{@model.sender}} · {{text "packet"}}</p><h1>{{@model.message}}</h1>
      <p class="rsc-price">{{formatAmount @model.total}} RSC</p>
      <p>{{@model.claimed_count}} / {{@model.count}} · {{text @model.status}}</p>
      {{#if this.currentUser}}<p>{{text "packet_membership_required"}}</p>
      {{else}}<p>{{text "packet_login_required"}}</p><LinkTo @route="login" class="btn btn-primary">{{text "login"}}</LinkTo>{{/if}}
      <p><LinkTo @route="discovery.latest">{{text "back_to_forum"}}</LinkTo></p>
    </section></main>
  </template>
}
