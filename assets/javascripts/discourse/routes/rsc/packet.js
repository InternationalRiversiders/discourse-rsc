import DiscourseRoute from "discourse/routes/discourse";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
export default class extends DiscourseRoute {
  @service currentUser;
  async model(params) {
    if (!this.currentUser?.rsc_member) {
      return ajax(`/rsc/packet/${encodeURIComponent(params.token)}/public.json`);
    }
    const state = await ajax("/rsc/state.json");
    state.packet = await ajax(
      `/rsc/packet/${encodeURIComponent(params.token)}.json`
    );
    return state;
  }
}
