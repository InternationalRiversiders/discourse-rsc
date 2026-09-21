import RscMemberRoute from "../../lib/rsc-member-route";
import { ajax } from "discourse/lib/ajax";

export default class extends RscMemberRoute {
  queryParams = {
    match_id: { refreshModel: true },
  };

  resetController(controller, isExiting) {
    if (isExiting) {
      controller.match_id = null;
    }
  }

  async model(params) {
    const state = await ajax("/rsc/state.json", { data: params });
    return { ...state, focus: params };
  }
}
