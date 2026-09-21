import RscDashboard from "../../components/rsc-dashboard";
import { array } from "@ember/helper";
export default <template>
 {{#each (array @controller.model) as |model|}}<RscDashboard @model={{model}} @section="market" />{{/each}}
</template>
