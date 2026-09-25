import { tracked } from "@glimmer/tracking";
import Controller from "@ember/controller";

export default class extends Controller {
  @tracked market_id = null;
  @tracked outcome = 0;
  queryParams = ["market_id", "outcome"];
}
