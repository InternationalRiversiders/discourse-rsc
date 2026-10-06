import RscMemberRoute from "../../lib/rsc-member-route";

export default class extends RscMemberRoute {
  queryParams = { journal_id: { refreshModel: true } };

  beforeModel(transition) {
    super.beforeModel(transition);
    if (transition.isAborted) {
      return;
    }
    const journal = transition.to.queryParams.journal_id;
    return journal
      ? this.router.replaceWith("rsc.wallet", { queryParams: { journal_id: journal } })
      : this.router.replaceWith("rsc.market");
  }
}
