import { array } from "@ember/helper";
import RscGames from "../components/rsc-games";
export default <template>{{#each (array @controller.model) key="@identity" as |model|}}<RscGames @model={{model}} />{{/each}}</template>;
