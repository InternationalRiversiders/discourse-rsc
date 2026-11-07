import { array } from "@ember/helper";
import RscGameHub from "../components/rsc-game-hub";
export default <template>{{#each (array @controller.model) key="@identity" as |model|}}<RscGameHub @model={{model}} />{{/each}}</template>;
