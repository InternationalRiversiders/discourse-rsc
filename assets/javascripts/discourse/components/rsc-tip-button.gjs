import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/ui-kit/d-button";
import TipModal from "./modal/rsc-tip";
export default class extends Component {
  @service modal;
  static shouldRender(args, context) {
    return (
      context.siteSettings.rsc_enabled &&
      context.siteSettings.rsc_native_trial_enabled &&
      !context.siteSettings.rsc_read_only &&
      context.currentUser?.rsc_member &&
      args.post.user_id !== context.currentUser.id &&
      args.post.post_type === context.site.post_types.regular &&
      !args.post.hidden &&
      !args.post.deleted_at &&
      !args.post.topic?.isPrivateMessage
    );
  }
  @action show() {
    this.modal.show(TipModal, { model: { post: this.args.post } });
  }
  <template>
    <DButton
      ...attributes
      class="rsc-tip-button"
      @icon="coins"
      @title="discourse_rsc.ui.post_tip"
      @action={{this.show}}
    />
  </template>
}
