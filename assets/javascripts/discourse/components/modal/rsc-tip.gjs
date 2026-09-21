import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { formatAmount } from "../../lib/rsc-format";
import { on } from "@ember/modifier";
import DModal from "discourse/ui-kit/d-modal";
import DButton from "discourse/ui-kit/d-button";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
export default class extends Component {
  @tracked amount = "1";
  @tracked busy = false;
  @tracked error = "";
  @tracked wallet;
  requestId;
  constructor() {
    super(...arguments);
    ajax("/rsc/wallet.json").then((wallet) => {
      if (!this.isDestroying && !this.isDestroyed) { this.wallet = wallet; }
    }).catch((error) => {
      if (!this.isDestroying && !this.isDestroyed) { this.error = extractError(error); }
    });
  }
  get disabled() {
    return this.busy || !this.wallet || this.wallet.read_only || this.wallet.status !== "active" || !/^(?:0|[1-9][0-9]*)(?:\.[0-9]{1,2})?$/.test(this.amount) || !/[1-9]/.test(this.amount);
  }
  @action change(event) {
    this.amount = event.target.value;
    this.requestId = undefined;
  }
  @action async submit(event) {
    event?.preventDefault();
    if (this.disabled) {
      return;
    }
    this.busy = true;
    this.error = "";
    this.requestId ||= crypto.randomUUID();
    try {
      await ajax("/rsc/tips.json", {
        type: "POST",
        data: {
          post_id: this.args.model.post.id,
          amount: this.amount,
          request_id: this.requestId,
        },
      });
      document.dispatchEvent(
        new CustomEvent("rsc:tip-updated", {
          detail: { postId: this.args.model.post.id },
        })
      );
      this.args.closeModal();
    } catch (error) {
      this.error = extractError(error);
    } finally {
      this.busy = false;
    }
  }
  <template>
    <DModal
      @title={{i18n "discourse_rsc.ui.post_tip"}}
      @closeModal={{@closeModal}}
      class="rsc-tip-modal"
    >
      <:body>
        <p>{{i18n "discourse_rsc.ui.recipient"}}:
          <a href="/u/{{@model.post.username}}" data-user-card={{@model.post.username}}>{{@model.post.username}}</a></p>
        {{#if this.wallet}}<p class="rsc-muted">{{i18n "discourse_rsc.ui.balance"}}：<strong title={{this.wallet.balance}}>{{formatAmount this.wallet.balance}} RSC</strong></p>{{#if this.wallet.status_reason}}<p>{{this.wallet.status_reason}}</p>{{/if}}{{/if}}
        {{#if this.error}}<div
            class="alert alert-error"
            role="alert"
          >{{this.error}}</div>{{/if}}
        <form {{on "submit" this.submit}}><label>{{i18n
              "discourse_rsc.ui.amount"
            }}<input
              required
              inputmode="decimal"
              value={{this.amount}}
              disabled={{this.busy}}
              {{on "input" this.change}}
            /></label></form>
      </:body>
      <:footer><DButton
          @label="discourse_rsc.ui.post_tip"
          @icon="coins"
          @action={{this.submit}}
          @disabled={{this.disabled}}
          class="btn-primary"
        /></:footer>
    </DModal>
  </template>
}
