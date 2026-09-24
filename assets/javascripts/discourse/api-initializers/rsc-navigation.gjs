import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";

export default apiInitializer((api) => {
  const user = api.getCurrentUser();
  const settings = api.container.lookup("service:site-settings");
  if (
    !settings.rsc_enabled ||
    !settings.rsc_native_trial_enabled ||
    (!user?.rsc_member && !user?.rsc_admin)
  ) {
    return;
  }

  api.addCommunitySectionLink((BaseLink) => {
    return class extends BaseLink {
      get name() {
        return "rsc";
      }

      get route() {
        return this.currentUser.rsc_member ? "rsc.index" : "rsc.admin";
      }

      get currentWhen() {
        return "rsc";
      }

      get text() {
        return i18n("discourse_rsc.navigation_title");
      }

      get title() {
        return this.text;
      }

      get defaultPrefixValue() {
        return "coins";
      }
    };
  });

  // Core appends API links after the configured community links. Reorder the
  // link model before rendering so desktop and mobile share the same order.
  api.modifyClass(
    "component:sidebar/common/custom-section",
    (Superclass) =>
      class extends Superclass {
        get initialSection() {
          const section = super.initialSection;
          if (this.args.sectionData.section_type !== "community") {
            return section;
          }

          const coin = section.links.find((link) => link.name === "rsc");
          if (!coin) {
            return section;
          }

          const collections = section.links.find(
            (link) => link.name === "collections"
          );
          const links = section.links.filter(
            (link) => link !== coin && link !== collections
          );
          const messagesIndex = links.findIndex(
            (link) => link.name === "my-messages"
          );
          const postsIndex = links.findIndex(
            (link) => link.name === "my-posts"
          );
          const position =
            messagesIndex >= 0
              ? messagesIndex + 1
              : postsIndex >= 0
                ? postsIndex + 1
                : links.length;
          links.splice(position, 0, ...[coin, collections].filter(Boolean));
          section.links = links;
          return section;
        }
      }
  );
});
