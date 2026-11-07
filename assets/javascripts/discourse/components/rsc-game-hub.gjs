import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { eq } from "truth-helpers";
import RscGames from "./rsc-games";
import RscArcade from "./rsc-arcade";
export default class extends Component {
 @tracked section='arcade';
 constructor(){super(...arguments);try{if(this.args.model.selected_round||localStorage.getItem('rsc-game-section')==='luck'){this.section='luck';}}catch{}}
 @action select(section){this.section=section;try{localStorage.setItem('rsc-game-section',section);}catch{}}
 <template><div class="ra-hub"><nav class="ra-sections" aria-label="游戏栏目"><button type="button" class={{if (eq this.section 'arcade') 'is-active'}} aria-pressed={{eq this.section 'arcade'}} {{on "click" (fn this.select 'arcade')}}>休闲挑战</button><button type="button" class={{if (eq this.section 'luck') 'is-active'}} aria-pressed={{eq this.section 'luck'}} {{on "click" (fn this.select 'luck')}}>幸运游戏</button></nav>{{#if (eq this.section 'arcade')}}<RscArcade />{{else}}<RscGames @model={{@model}} />{{/if}}</div></template>
}
