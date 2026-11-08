import Component from "@glimmer/component";
import { modifier } from "ember-modifier";
import drawCover from "../lib/arcade-cover";
export default class extends Component {
 art=modifier((canvas,[game])=>drawCover(canvas,game));
 <template><canvas class="ra-art ra-cover" data-game={{@game}} aria-hidden="true" {{this.art @game}}></canvas></template>
}
