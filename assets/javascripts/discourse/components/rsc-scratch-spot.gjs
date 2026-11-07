import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { modifier } from "ember-modifier";

export default class extends Component {
  @tracked opened = false;
  get visible() { return this.opened || this.args.revealed; }
  @action reveal() {
    if (!this.args.purchased || this.visible) { return; }
    this.opened = true;
    this.args.onReveal();
  }
  coating = modifier((canvas) => {
    const ctx = canvas.getContext("2d");
    if (!ctx) { return; } // The accessible button still reveals the spot.
    let down = false, last = null, oldWidth = 0, oldHeight = 0;
    const paint = () => {
      const { width, height } = canvas.getBoundingClientRect();
      if (width === oldWidth && height === oldHeight) { return; }
      const saved = document.createElement("canvas");
      saved.width = canvas.width; saved.height = canvas.height;
      if (oldWidth) { saved.getContext("2d").drawImage(canvas, 0, 0); }
      const scale = Math.min(devicePixelRatio || 1, 2);
      canvas.width = Math.round(width * scale); canvas.height = Math.round(height * scale);
      ctx.setTransform(scale, 0, 0, scale, 0, 0);
      if (oldWidth) {
        ctx.drawImage(saved, 0, 0, saved.width, saved.height, 0, 0, width, height);
      } else {
        const gradient = ctx.createLinearGradient(0, 0, width, height);
        gradient.addColorStop(0, "#ead8a4"); gradient.addColorStop(.45, "#b8a16a"); gradient.addColorStop(1, "#eee0b5");
        ctx.fillStyle = gradient; ctx.fillRect(0, 0, width, height);
        ctx.fillStyle = "#715c34"; ctx.textAlign = "center"; ctx.textBaseline = "middle";
        ctx.font = "600 14px sans-serif"; ctx.fillText("刮开好运", width / 2, height / 2);
      }
      oldWidth = width; oldHeight = height;
    };
    const position = e => { const r = canvas.getBoundingClientRect(); return [e.clientX - r.left, e.clientY - r.top]; };
    const draw = e => {
      if (!down) { return; }
      const p = position(e); ctx.globalCompositeOperation = "destination-out";
      ctx.lineWidth = 30; ctx.lineCap = "round"; ctx.beginPath(); ctx.moveTo(...(last || p)); ctx.lineTo(...p); ctx.stroke(); last = p;
    };
    const start = e => { if (e.button !== 0) { return; } down = true; last = position(e); canvas.setPointerCapture(e.pointerId); draw(e); };
    const end = () => {
      if (!down) { return; } down = false; last = null;
      const data = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
      let cleared = 0, total = 0;
      for (let i = 3; i < data.length; i += 16) { total++; if (data[i] < 128) { cleared++; } }
      if (total && cleared / total > .4) { this.reveal(); }
    };
    const observer = new ResizeObserver(paint); observer.observe(canvas);
    canvas.addEventListener("pointerdown", start); canvas.addEventListener("pointermove", draw);
    canvas.addEventListener("pointerup", end); canvas.addEventListener("pointercancel", end);
    return () => {
      observer.disconnect(); canvas.removeEventListener("pointerdown", start); canvas.removeEventListener("pointermove", draw);
      canvas.removeEventListener("pointerup", end); canvas.removeEventListener("pointercancel", end);
    };
  });

  <template>
    <div class="rg-ticket-spot {{if this.visible 'is-open'}} {{if @spot.won 'has-prize'}}">
      <span class="rg-ticket-spot-number">{{@spot.label}}</span>
      <div class="rg-ticket-spot-face">
        {{#if @purchased}}
          <div class="rg-ticket-spot-prize" aria-hidden={{if this.visible "false" "true"}}>
            {{#if @spot.won}}<strong>{{@spot.payout}} <small>RSC</small></strong><span>{{@spot.multiplier}} 倍</span>{{else}}<strong class="rg-ticket-no-prize">未中奖</strong><span>0 RSC</span>{{/if}}
          </div>
          {{#unless this.visible}}<canvas class="rg-ticket-spot-cover" aria-hidden="true" {{this.coating}}></canvas><button class="rg-ticket-keyboard-reveal" type="button" aria-label="刮开第 {{@spot.label}} 位" {{on "click" this.reveal}}>刮开</button>{{/unless}}
        {{else}}
          <div class="rg-ticket-spot-preview">✦</div>
        {{/if}}
      </div>
    </div>
  </template>
}
