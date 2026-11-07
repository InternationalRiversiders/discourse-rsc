import DiscourseRoute from "discourse/routes/discourse";
import { ajax } from "discourse/lib/ajax";
export default class extends DiscourseRoute {
  model() { return ajax("/rsc/lottery/state.json"); }
  titleToken() { return "Riverside 大乐透"; }
}
