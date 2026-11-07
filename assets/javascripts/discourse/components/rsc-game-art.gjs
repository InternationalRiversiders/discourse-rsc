import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { modifier } from "ember-modifier";
import { eq } from "truth-helpers";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import getURL from "discourse/lib/get-url";
import { createGameScene, supports3d } from "../lib/game-3d";
import { applyCover, attract, COVER_VERSION } from "../lib/game-covers";

// Covers are stills pre-rendered from the 3D scenes (script/render-game-covers.cjs);
// the drawn art underneath shows until the image loads. Hovering with a mouse mounts
// the live scene running a short demo loop.
export default class extends Component {
  @tracked loaded = false;
  get src() { const version = this.args.game === "scratch" ? "v2" : COVER_VERSION; return getURL(`/plugins/discourse-rsc/images/games/cover-${this.args.game}-${version}.webp`); }
  @action onLoad() { this.loaded = true; }
  cover = modifier((el, [game]) => {
    let alive = true, ctl = null, stop = null, host = null, token = 0;
    const card = el.closest(".rg-game-card") || el;
    const hover = window.matchMedia?.("(hover: hover) and (pointer: fine)").matches;
    const enter = async () => {
      const mine = ++token;
      host = document.createElement("div");
      host.className = "rg-art-live";
      el.appendChild(host);
      try {
        const c = await createGameScene(game, host, { cover: true });
        if (mine !== token || !alive) { c.dispose(); return; }
        ctl = c;
        applyCover(c, game);
        host.classList.add("is-ready");
        stop = attract(c, game);
      } catch { /* the still cover remains */ }
    };
    const leave = () => {
      token++;
      stop?.();
      stop = null;
      const c = ctl, h = host;
      ctl = host = null;
      h?.classList.remove("is-ready");
      if (h) { setTimeout(() => { c?.dispose(); h.remove(); }, 320); }
    };
    if (hover && supports3d(game)) {
      card.addEventListener("pointerenter", enter);
      card.addEventListener("pointerleave", leave);
    }
    return () => {
      alive = false;
      card.removeEventListener("pointerenter", enter);
      card.removeEventListener("pointerleave", leave);
      leave();
    };
  });
  <template>
    <div class="rg-art rg-art--{{@game}} {{if this.loaded 'has-cover'}}" aria-hidden="true" {{this.cover @game}}>
      <img class="rg-art-cover" src={{this.src}} alt="" decoding="async" {{on "load" this.onLoad}} />
      {{#if (eq @game "slots")}}<div class="rg-mini-slots"><span>7</span><span>7</span><span>7</span></div><i class="rg-lever"></i>{{/if}}
      {{#if (eq @game "roulette")}}<div class="rg-mini-wheel"><span>0</span></div><i class="rg-chip">25</i>{{/if}}
      {{#if (eq @game "scratch")}}<div class="rg-mini-ticket"><span>刮刮乐</span><strong>★ ★ ★</strong><small>RSC</small></div>{{/if}}
      {{#if (eq @game "blackjack")}}<div class="rg-mini-card rg-mini-card--back">K<span>♠</span></div><div class="rg-mini-card">A<span>♥</span></div>{{/if}}
      {{#if (eq @game "coin")}}<div class="rg-mini-coin rg-mini-coin--back">R</div><div class="rg-mini-coin">R</div>{{/if}}
      {{#if (eq @game "dice")}}<div class="rg-mini-die">⚄</div><div class="rg-mini-die rg-mini-die--second">⚂</div>{{/if}}
    </div>
  </template>
}
