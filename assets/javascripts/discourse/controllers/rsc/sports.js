import Controller from "@ember/controller";
import { tracked } from "@glimmer/tracking";
export default class extends Controller {
  queryParams = ["match_id"];
  @tracked match_id = null;
}
