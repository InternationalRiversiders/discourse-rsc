import Controller from "@ember/controller";
import { tracked } from "@glimmer/tracking";
export default class extends Controller {
  queryParams = ["journal_id"];
  @tracked journal_id = null;
}
