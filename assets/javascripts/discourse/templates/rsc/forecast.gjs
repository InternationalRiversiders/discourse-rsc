import { array } from "@ember/helper";
import RscForecast from "../../components/rsc-forecast";

export default <template>
  {{#each (array @controller.model) as |model|}}<RscForecast @model={{model}} />{{/each}}
</template>
