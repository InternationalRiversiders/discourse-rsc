import RscMemberRoute from "../../lib/rsc-member-route";

export default class extends RscMemberRoute {
  // The destination owns journal_id. Registering it here too lets an aborted
  // index transition reset the wallet query parameter during the redirect.
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
