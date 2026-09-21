import { apiInitializer } from "discourse/lib/api";
import PostTips from "../components/rsc-post-tips";
import TipButton from "../components/rsc-tip-button";
export default apiInitializer((api) => {
  if (!api.container.lookup("service:site-settings").rsc_enabled || !api.container.lookup("service:site-settings").rsc_native_trial_enabled) {
    return;
  }
  api.renderAfterWrapperOutlet("post-content-cooked-html", PostTips);
  api.registerValueTransformer("post-menu-buttons", ({ value: dag }) => {
    dag.add("rsc-tip", TipButton, { before: "reply" });
  });
});
