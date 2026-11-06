import { apiInitializer } from "discourse/lib/api";
export default apiInitializer((api) => {
  const s=api.container.lookup("service:site-settings");
  if (s.alumni_map_enabled || !s.rsc_enabled || !s.rsc_games_enabled || !api.getCurrentUser()?.rsc_member) { return; }
  api.addSidebarSection((BaseSection, BaseLink) => class extends BaseSection {
    get name() { return "campus-games"; }
    get title() { return "校园生活"; }
    get text() { return this.title; }
    get displaySection() { return true; }
    get links() { return [new (class extends BaseLink {
      get name() { return "rsc-games"; }
      get route() { return "rsc-games"; }
      get text() { return "游戏"; }
      get title() { return this.text; }
      get prefixType() { return "icon"; }
      get prefixValue() { return "dice"; }
    })()]; }
  });
});
