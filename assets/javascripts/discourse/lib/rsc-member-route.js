import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";

// Administration and wallet membership are separate permissions. An admin-only
// account must not enter a member route and fail while loading its model.
export default class RscMemberRoute extends DiscourseRoute {
  @service currentUser;
  @service router;

  beforeModel(transition) {
    if (this.currentUser?.rsc_admin && !this.currentUser.rsc_member) {
      return this.router.replaceWith("rsc.admin");
    }
    return super.beforeModel(transition);
  }
}
