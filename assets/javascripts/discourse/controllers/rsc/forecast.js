import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";

export default class extends Controller {
  @tracked section = null;
  @tracked market_id = null;
  @tracked outcome = 0;
  queryParams = ["market_id", "outcome", "section"];
}
