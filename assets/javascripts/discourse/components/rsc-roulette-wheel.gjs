import Component from '@glimmer/component';
const ORDER = [0,32,15,19,4,21,2,25,17,34,6,27,13,36,11,30,8,23,10,5,24,16,33,1,20,14,31,9,22,18,29,7,28,12,35,3,26];
const RED = [1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
export default class extends Component {
  get numbers() { return ORDER.map((n,i) => ({n,style:`transform: rotate(${i*360/37}deg)`,color:n===0?'zero':RED.includes(n)?'red':'black'})); }
  get angle() { return this.args.number === undefined ? 0 : -ORDER.indexOf(this.args.number)*360/37; }
  get discStyle() { return `transform: rotate(${this.angle}deg)`; }
  get label() { return this.args.spinning ? '轮盘转动中' : this.args.number === undefined ? '幸运转盘' : `开奖号码 ${this.args.number}`; }
  <template>
    <div class="rg-roulette-scene" role="img" aria-label={{this.label}}>
      <div class="rg-roulette-wheel">
        <div class="rg-wheel-disc" style={{this.discStyle}} data-angle={{this.angle}}>{{#each this.numbers as |item|}}<span class="rg-wheel-number rg-wheel-number--{{item.color}}" style={{item.style}}>{{item.n}}</span>{{/each}}</div>
        <div class="rg-wheel-center"><span>{{if @spinning "R" (if @hasRound @number "R")}}</span><i class="rg-wheel-spindle"></i></div>
        <div class="rg-ball-orbit"><span class="rg-wheel-ball"></span></div>
        <span class="rg-wheel-pointer"></span>
      </div>
    </div>
  </template>
}
