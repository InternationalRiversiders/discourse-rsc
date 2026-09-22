import Service from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import TipRequests from "../lib/rsc-tip-requests";

export default class extends Service {
  requests = new TipRequests({
    request: (topicId, ids) => ajax(`/rsc/topics/${topicId}/tips.json`, {
      data: { post_ids: ids.join(",") },
    }),
  });

  get(post, refresh = false) {
    return this.requests.get(post, refresh);
  }

  willDestroy() {
    this.requests.destroy();
    super.willDestroy(...arguments);
  }
}
