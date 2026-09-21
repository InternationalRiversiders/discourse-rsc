import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";
export default apiInitializer((api) => {
  // The shared Campus Life section owns application links when installed.
  if (api.container.lookup("service:site-settings").alumni_map_enabled) { return; }
  const user = api.getCurrentUser();
  const settings = api.container.lookup("service:site-settings");
  if (
    !settings.rsc_enabled ||
    !settings.rsc_native_trial_enabled ||
    (!user?.rsc_member && !user?.rsc_admin)
  ) {
    return;
  }
  api.addSidebarSection((BaseSection, BaseLink) => {
    const routes = user.rsc_member
      ? [
          ["wallet", "rsc.index"],
          ["market", "rsc.market"],
          ["sports", "rsc.sports"],
          ["leaderboard", "rsc.leaderboard"],
        ]
      : [];
    if (user.rsc_admin) {
      routes.push(["administration", "rsc.admin"]);
    }
    const links = routes.map(
      ([key, route]) =>
        new (class extends BaseLink {
          get name() {
            return `rsc-${key}`;
          }
          get route() {
            return route;
          }
          get text() {
            return i18n(`discourse_rsc.ui.${key}`);
          }
          get title() {
            return this.text;
          }
          get prefixType() {
            return "icon";
          }
          get prefixValue() {
            return "coins";
          }
        })()
    );
    return class extends BaseSection {
      get name() {
        return "rsc";
      }
      get title() {
        return "RSC";
      }
      get text() {
        return "RSC";
      }
      get links() {
        return links;
      }
      get displaySection() {
        return true;
      }
    };
  });
});
