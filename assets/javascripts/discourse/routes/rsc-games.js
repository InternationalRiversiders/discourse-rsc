import DiscourseRoute from "discourse/routes/discourse";
import { ajax } from "discourse/lib/ajax";
export default class extends DiscourseRoute {
  queryParams = { round_id: { refreshModel: true } };
  resetController(controller, isExiting) { if (isExiting) { controller.round_id = null; } }
  model(params) { return ajax("/rsc/games/state.json", { data: { round_id: params.round_id } }); }
  titleToken() { return "游戏"; }
}
