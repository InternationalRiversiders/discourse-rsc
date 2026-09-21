import RscMemberRoute from "../../lib/rsc-member-route";
import { ajax } from "discourse/lib/ajax";
export default class extends RscMemberRoute {
  model() {
    return ajax("/rsc/ranking.json");
  }
}
