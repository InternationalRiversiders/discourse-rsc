import Controller from "@ember/controller";
import { tracked } from "@glimmer/tracking";
export default class extends Controller {
  queryParams = ["round_id"];
  @tracked round_id = null;
}
