import Component from "@glimmer/component";
import { eq } from "truth-helpers";
export default class extends Component {
  <template>
    <div class="rg-art rg-art--{{@game}}" aria-hidden="true">
      {{#if (eq @game "slots")}}<div class="rg-mini-slots"><span>7</span><span>7</span><span>7</span></div><i class="rg-lever"></i>{{/if}}
      {{#if (eq @game "roulette")}}<div class="rg-mini-wheel"><span>0</span></div><i class="rg-chip">25</i>{{/if}}
      {{#if (eq @game "scratch")}}<div class="rg-mini-ticket"><span>幸运刮刮乐</span><strong>★ ★ ★</strong><small>RSC</small></div>{{/if}}
      {{#if (eq @game "blackjack")}}<div class="rg-mini-card rg-mini-card--back">K<span>♠</span></div><div class="rg-mini-card">A<span>♥</span></div>{{/if}}
      {{#if (eq @game "coin")}}<div class="rg-mini-coin rg-mini-coin--back">R</div><div class="rg-mini-coin">R</div>{{/if}}
      {{#if (eq @game "dice")}}<div class="rg-mini-die">⚄</div><div class="rg-mini-die rg-mini-die--second">⚂</div>{{/if}}
    </div>
  </template>
}
