import DiscourseRoute from "discourse/routes/discourse";
import { ajax } from "discourse/lib/ajax";
export default class extends DiscourseRoute {
  model() { return ajax("/rsc/games/state.json"); }
  titleToken() { return "游戏"; }
}
