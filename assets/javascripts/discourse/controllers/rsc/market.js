import Controller from "@ember/controller";
import { tracked } from "@glimmer/tracking";
export default class extends Controller {
  queryParams = ["instrument_id", "order_id"];
  @tracked instrument_id = null;
  @tracked order_id = null;
}
