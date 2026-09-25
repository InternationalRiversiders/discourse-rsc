import { ajax } from "discourse/lib/ajax";
import RscMemberRoute from "../../lib/rsc-member-route";

export default class extends RscMemberRoute {
  queryParams = { section: { refreshModel: true }, market_id: { refreshModel: true }, outcome: { refreshModel: true } };

  async model(params) {
    const [state, detail] = await Promise.all([
      ajax("/rsc/forecast/state.json"),
      params.market_id ? ajax(`/rsc/forecast/markets/${encodeURIComponent(params.market_id)}.json`) : null,
    ]);
    return { ...state, detail, initialSection: params.section, initialOutcome: String(params.outcome) === "1" ? 1 : 0 };
  }
}
