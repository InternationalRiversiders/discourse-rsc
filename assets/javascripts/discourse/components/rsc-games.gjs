import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn, concat } from "@ember/helper";
import { modifier } from "ember-modifier";
import { eq, and, not } from "truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import RscGameArt from "./rsc-game-art";
import { formatDateTime } from "../lib/campus-time";

const GAMES=[
  {id:"slots",name:"三轴老虎机",mark:"01",color:"violet"},
  {id:"roulette",name:"欧式轮盘",mark:"02",color:"green"},
  {id:"scratch",name:"刮刮乐",mark:"03",color:"gold"},
  {id:"blackjack",name:"二十一点",mark:"04",color:"blue"},
  {id:"coin",name:"抛硬币",mark:"05",color:"rose"},
  {id:"dice",name:"骰子大小",mark:"06",color:"teal"},
];
const SYMBOLS={cherry:"🍒",lemon:"🍋",bell:"🔔",clover:"🍀",diamond:"💎",seven:"7"};
const RED=[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
const WHEEL=[0,32,15,19,4,21,2,25,17,34,6,27,13,36,11,30,8,23,10,5,24,16,33,1,20,14,31,9,22,18,29,7,28,12,35,3,26];
const RULES={
  slots:["每轴 6 种图案，独立且等概率。左起两个相同返还 1 倍；三个相同时按下表返还，不叠加。","🍒 5 倍 · 🍋 8 倍 · 🔔 12 倍 · 🍀 20 倍 · 💎 40 倍 · 7 96 倍","长期理论返还率 97.69%。"],
  roulette:["单零轮盘，0–36 共 37 个数字等概率。点击投注格放入当前金额，可同时选多个位置。","单号 36 倍；列、组 3 倍；红黑、单双、大小 2 倍。开出 0 时，只有单号 0 获奖。","长期理论返还率 97.30%。"],
  scratch:["刮出三个相同倍数，按该倍数返还；无三连则未中奖。购票即结算，刮开与刷新不改变结果。","0 倍 57% · 1 倍 19% · 2 倍 18% · 5 倍 5% · 10 倍 0.9% · 50 倍 0.09% · 250 倍 0.01%","长期理论返还率 96%。"],
  blackjack:["每局重新洗入 6 副牌。A 算 1 或 11，J/Q/K 算 10。比庄家更接近 21 点获胜，超过 21 点即输。","庄家软 17 点停牌，并在开局检查天然 21 点。天然 21 点返还 2.5 倍，普通胜利返还 2 倍，平局退还本金。","前两张牌可加倍：追加同额投入，只再取一张牌。不设分牌、保险和投降。断线后可继续原牌局。"],
  coin:["正面与反面各 50% 概率。猜中返还 1.96 倍。","长期理论返还率 98%。"],
  dice:["三颗公平六面骰。小为 4–10 点，大为 11–17 点。三个相同为豹子，大小都不获奖。","猜中返还 2 倍，长期理论返还率 97.22%。"],
};
const money=(n)=>Number(n||0).toLocaleString("zh-CN",{maximumFractionDigits:2});
const card=(n,i)=>{
  if(n===null){return {key:i,hidden:true};}
  const suits=["♠","♥","♣","♦"],rank=n%13;
  return {key:i,rank:["A","2","3","4","5","6","7","8","9","10","J","Q","K"][rank],suit:suits[Math.floor(n/13)],red:[1,3].includes(Math.floor(n/13))};
};
export default class extends Component {
  @tracked game=null;
  @tracked balance=this.args.model.balance;
  @tracked history=this.args.model.history||[];
  @tracked cursor=this.args.model.next_cursor;
  @tracked active=this.args.model.active;
  @tracked walletStatus=this.args.model.wallet_status;
  @tracked readOnly=this.args.model.read_only;
  @tracked round=null;
  @tracked stake="10";
  @tracked choice="heads";
  @tracked bets={};
  @tracked busy=false;
  @tracked loading=false;
  @tracked pending=null;
  @tracked error="";
  @tracked rules=false;
  @tracked showHistory=false;
  @tracked revealed=false;
  games=GAMES;
  chips=[5,10,25,50];
  get name(){return GAMES.find(g=>g.id===this.game)?.name;}
  get rulesLines(){return RULES[this.game]||[];}
  get maxStake(){return this.args.model.max_stake;}
  get balanceLabel(){return money(this.balance);}
  get blocked(){return this.busy||this.readOnly||this.walletStatus!=="active";}
  get locked(){return this.blocked||!!this.pending;}
  get playing(){return this.round?.game==="blackjack"&&this.round?.status==="playing";}
  get total(){return this.game==="roulette" ? Object.values(this.bets).reduce((a,b)=>a+b,0) : Number(this.stake)||0;}
  get totalLabel(){return money(this.total);}
  get startDisabled(){return this.blocked||this.playing||(!this.pending&&(!Number.isFinite(this.total)||this.total<1||this.total>this.maxStake||this.total>Number(this.balance)));}
  get doubleDisabled(){return this.blocked||!!this.pending||!this.round?.state.can_double||Number(this.balance)<Number(this.round?.stake);}
  get netLabel(){const n=Number(this.round?.net);return `${n>0?"+":""}${money(n)} RSC`;}
  get tone(){return Number(this.round?.net)>0?"win":Number(this.round?.net)<0?"loss":"push";}
  get outcomeTitle(){return {win:"获胜",lose:"未中奖",push:"平局",bust:"爆牌",blackjack:"Blackjack"}[this.round?.state.result]||"";}
  get showResult(){return !this.pending&&this.round?.status==="settled"&&(this.game!=="scratch"||this.revealed);}
  get reels(){return (this.round?.state.symbols||["seven","seven","seven"]).map((x,i)=>({key:i,symbol:SYMBOLS[x]}));}
  get dice(){return (this.round?.state.dice||[1,3,5]).map((x,i)=>({key:i,symbol:["⚀","⚁","⚂","⚃","⚄","⚅"][x-1]}));}
  get player(){return (this.round?.state.player||[0,22]).map(card);}
  get dealer(){return (this.round?.state.dealer||[11,null]).map(card);}
  get tiles(){return (this.round?.state.tiles||[1,2,5,10,50,250,1,2,5]).map((x,i)=>({key:i,value:x}));}
  get coinSide(){return this.round?.state.landed==="tails"?"反":"正";}
  get wheelNumbers(){return WHEEL.map((n,i)=>({n,style:`transform: rotate(${i*360/37}deg)`,color:n===0?"zero":RED.includes(n)?"red":"black"}));}
  get wheelStyle(){const n=this.round?.state.number;return `transform: rotate(${n===undefined?0:1080-WHEEL.indexOf(n)*360/37}deg)`;}
  get numberRows(){return [3,2,1].map(start=>Array.from({length:12},(_,i)=>start+i*3).map(n=>this.spot(`n${n}`,n,RED.includes(n)?"red":"black")));}
  get zero(){return this.spot("n0","0","zero");}
  get outside(){return [["low","1–18"],["even","双"],["red","红"],["black","黑"],["odd","单"],["high","19–36"]].map(([key,label])=>this.spot(key,label,key));}
  get dozens(){return [["dozen1","1–12"],["dozen2","13–24"],["dozen3","25–36"]].map(([key,label])=>this.spot(key,label));}
  get columns(){return [1,2,3].map(n=>this.spot(`column${n}`,`${n} / ${n+3} / ${n+6} …`));}
  get rows(){return this.history.map(r=>({...r,time:formatDateTime(r.created_at),netLabel:r.net===null?"进行中":`${Number(r.net)>0?"+":""}${money(r.net)}`,tone:Number(r.net)>0?"win":Number(r.net)<0?"loss":"push"}));}
  spot(key,label,color=""){return {key,label,color,amount:this.bets[key]?money(this.bets[key]):null,selected:!!this.bets[key]};}
  @action open(id){if(this.busy||this.pending){return;} this.game=id;this.round=id==="blackjack"?this.active:null;this.choice=id==="dice"?"small":"heads";this.rules=false;this.error="";this.revealed=false;}
  @action back(){if(!this.busy&&!this.pending){this.game=null;this.rules=false;this.error="";}}
  @action editStake(e){this.stake=e.target.value;}
  @action chip(n){if(!this.locked){this.stake=String(n);}}
  @action pick(choice){if(!this.locked){this.choice=choice;}}
  @action bet(key){if(this.locked){return;} const amount=Number(this.stake); if(!Number.isFinite(amount)||amount<1||Math.abs(amount*100-Math.round(amount*100))>1e-8||this.total+amount>Math.min(this.maxStake,Number(this.balance))){this.error="请检查投入金额和可用余额。";return;}this.error="";this.bets={...this.bets,[key]:Math.round(((this.bets[key]||0)+amount)*100)/100};}
  @action clearBets(){this.bets={};}
  @action toggleRules(){this.rules=!this.rules;}
  @action toggleHistory(){this.showHistory=!this.showHistory;}
  @action reveal(){this.revealed=true;}
  @action inspect(r){if(this.busy||this.pending){return;}this.game=r.game;this.round=r;this.revealed=true;this.showHistory=false;this.rules=false;this.error="";}
  @action async refresh(){
    if(this.loading||this.busy){return;} this.loading=true;
    try{const data=await ajax("/rsc/games/state.json");if(this.isDestroying||this.isDestroyed){return;}this.balance=data.balance;this.history=data.history;this.cursor=data.next_cursor;this.active=data.active;this.walletStatus=data.wallet_status;this.readOnly=data.read_only;if(this.game==="blackjack"){this.round=data.active||data.history.find(r=>r.id===this.round?.id)||null;}}
    catch(e){if(!this.isDestroying&&!this.isDestroyed){this.error=extractError(e);}}
    finally{if(!this.isDestroying&&!this.isDestroyed){this.loading=false;}}
  }
  @action async more(){if(this.loading||!this.cursor){return;}this.loading=true;try{const data=await ajax("/rsc/games/state.json",{data:{before:this.cursor}});if(!this.isDestroying&&!this.isDestroyed){this.history=[...this.history,...data.history];this.cursor=data.next_cursor;}}catch(e){this.error=extractError(e);}finally{this.loading=false;}}
  @action play(){if(this.startDisabled){return;} if(this.pending){return this.send(this.pending);}const data={game:this.game,stake:this.stake,choice:["coin","dice"].includes(this.game)?this.choice:null,bets:Object.entries(this.bets).map(([choice,stake])=>({choice,stake:String(stake)})),request_id:crypto.randomUUID()};return this.send({url:"/rsc/games/play.json",data});}
  @action move(move){if(this.blocked||this.pending){return;}return this.send({url:`/rsc/games/${this.round.id}/action.json`,data:{move,version:this.round.version,request_id:crypto.randomUUID()}});}
  @action retry(){if(this.pending&&!this.busy){return this.send(this.pending);}}
  async send(request){
    this.busy=true;this.error="";this.pending=request;
    try{
      const result=await ajax(request.url,{type:"POST",contentType:"application/json",data:JSON.stringify(request.data)});
      if(this.isDestroying||this.isDestroyed){return;}
      this.round=result;this.balance=result.balance;this.pending=null;this.revealed=false;
      if(result.game==="blackjack"){this.active=result.status==="playing"?result:null;}
      this.history=[result,...this.history.filter(r=>r.id!==result.id)].slice(0,Math.max(20,this.history.length));
    }catch(e){
      if(this.isDestroying||this.isDestroyed){return;}
      const status=e.jqXHR?.status||e.status;
      if(status>=400&&status<500){this.pending=null;this.error=extractError(e);}
      else{this.error="结果暂未确认，请重试同一请求，不会重复扣款。";}
    }finally{if(!this.isDestroying&&!this.isDestroyed){this.busy=false;}}
  }
  scratch = modifier((canvas,[id])=>{
    if(!id){return;}
    let down=false,last=null;const context=canvas.getContext("2d");
    const paint=()=>{const box=canvas.getBoundingClientRect(),scale=devicePixelRatio||1;canvas.width=box.width*scale;canvas.height=box.height*scale;context.setTransform(scale,0,0,scale,0,0);context.globalCompositeOperation="source-over";const g=context.createLinearGradient(0,0,box.width,box.height);g.addColorStop(0,"#eee4b8");g.addColorStop(.5,"#b9a76e");g.addColorStop(1,"#e7dcb2");context.fillStyle=g;context.fillRect(0,0,box.width,box.height);context.fillStyle="#62542f";context.font="600 18px sans-serif";context.textAlign="center";context.fillText("刮开好运",box.width/2,box.height/2);};
    const position=e=>{const b=canvas.getBoundingClientRect();return [e.clientX-b.left,e.clientY-b.top];};
    const draw=e=>{if(!down){return;}const p=position(e);context.globalCompositeOperation="destination-out";context.lineWidth=45;context.lineCap="round";context.beginPath();context.moveTo(...(last||p));context.lineTo(...p);context.stroke();last=p;};
    const start=e=>{down=true;last=position(e);canvas.setPointerCapture(e.pointerId);draw(e);};
    const end=()=>{down=false;last=null;const pixels=context.getImageData(0,0,canvas.width,canvas.height).data;let clear=0,total=0;for(let i=3;i<pixels.length;i+=64){total++;if(pixels[i]<128){clear++;}}if(clear/total>.45){this.revealed=true;}};
    const observer=new ResizeObserver(paint);observer.observe(canvas);canvas.addEventListener("pointerdown",start);canvas.addEventListener("pointermove",draw);canvas.addEventListener("pointerup",end);canvas.addEventListener("pointercancel",end);
    return()=>{observer.disconnect();canvas.removeEventListener("pointerdown",start);canvas.removeEventListener("pointermove",draw);canvas.removeEventListener("pointerup",end);canvas.removeEventListener("pointercancel",end);};
  });
  <template>
    <section class="rg-app" aria-label="游戏">
      <header class="rg-topbar">
        <div class="rg-brand">{{#if this.game}}<button type="button" class="rg-icon-button" title="返回游戏" aria-label="返回游戏" disabled={{this.locked}} {{on "click" this.back}}>{{dIcon "arrow-left"}}</button>{{else}}<span class="rg-brand-icon">{{dIcon "dice"}}</span>{{/if}}<h1>{{if this.game this.name "游戏"}}</h1></div>
        <div class="rg-top-actions"><span class="rg-balance">{{dIcon "coins"}}<strong>{{this.balanceLabel}}</strong><small>RSC</small></span><button type="button" class="rg-icon-button" title="刷新余额" aria-label="刷新余额" disabled={{this.busy}} {{on "click" this.refresh}}>{{dIcon "arrows-rotate"}}</button><button type="button" class="rg-icon-button" title="我的记录" aria-label="我的记录" aria-expanded={{this.showHistory}} {{on "click" this.toggleHistory}}>{{dIcon "clock-rotate-left"}}</button></div>
      </header>
      {{#if this.error}}<div class="rg-error" role="alert">{{this.error}}{{#if this.pending}}<button type="button" disabled={{this.busy}} {{on "click" this.retry}}>重试同一请求</button>{{else}}<button type="button" disabled={{this.busy}} {{on "click" this.refresh}}>刷新</button>{{/if}}</div>{{/if}}
      {{#if this.readOnly}}<div class="rg-notice">游戏暂时维护中</div>{{else if (not (eq this.walletStatus "active"))}}<div class="rg-notice">钱包已冻结，暂不能参与游戏</div>{{/if}}
      {{#unless this.game}}
        {{#if this.active}}<button type="button" class="rg-resume" {{on "click" (fn this.open "blackjack")}}><span>♠</span>继续二十一点<strong>返回牌局 →</strong></button>{{/if}}
        <div class="rg-lobby">{{#each this.games as |game|}}<button type="button" class="rg-game-card rg-game-card--{{game.color}}" {{on "click" (fn this.open game.id)}}><span class="rg-card-number">{{game.mark}}</span><RscGameArt @game={{game.id}} /><div class="rg-card-bottom"><h2>{{game.name}}</h2><span class="rg-card-arrow">↗</span></div></button>{{/each}}</div>
      {{else}}
        <nav class="rg-tabs" aria-label="选择游戏">{{#each this.games as |game|}}<button type="button" class={{if (eq this.game game.id) "is-selected"}} disabled={{this.locked}} aria-pressed={{eq this.game game.id}} {{on "click" (fn this.open game.id)}}>{{game.name}}</button>{{/each}}</nav>
        <div class="rg-play-layout">
          <div class="rg-stage rg-stage--{{this.game}} {{if this.busy 'is-busy'}}" aria-busy={{this.busy}}>
            {{#if (eq this.game "slots")}}
              <div class="rg-slot-machine"><div class="rg-slot-top"><span>RIVERSIDE</span><span>★ ★ ★</span></div><div class="rg-reels">{{#each this.reels as |reel|}}<div class="rg-reel">{{reel.symbol}}</div>{{/each}}</div><div class="rg-slot-base"><span>● ● ●</span><strong>777</strong></div></div>
            {{else if (eq this.game "roulette")}}
              <div class="rg-roulette-wheel"><span class="rg-wheel-pointer"></span><div class="rg-wheel-disc" style={{this.wheelStyle}}>{{#each this.wheelNumbers as |item|}}<span class="rg-wheel-number rg-wheel-number--{{item.color}}" style={{item.style}}>{{item.n}}</span>{{/each}}</div><div class="rg-wheel-center">{{#if this.round}}{{this.round.state.number}}{{else}}R{{/if}}</div></div>
              <div class="rg-betting-board">
                <button type="button" class="rg-spot zero {{if this.zero.selected 'is-selected'}}" disabled={{this.locked}} {{on "click" (fn this.bet "n0")}}>0{{#if this.zero.amount}}<small>{{this.zero.amount}}</small>{{/if}}</button>
                <div class="rg-number-board">{{#each this.numberRows as |row|}}{{#each row as |spot|}}<button type="button" class="rg-spot {{spot.color}} {{if spot.selected 'is-selected'}}" disabled={{this.locked}} {{on "click" (fn this.bet spot.key)}}>{{spot.label}}{{#if spot.amount}}<small>{{spot.amount}}</small>{{/if}}</button>{{/each}}{{/each}}</div>
                <div class="rg-outside rg-outside--three">{{#each this.columns as |spot|}}<button type="button" class="rg-spot {{if spot.selected 'is-selected'}}" disabled={{this.locked}} {{on "click" (fn this.bet spot.key)}}>{{spot.label}}{{#if spot.amount}}<small>{{spot.amount}}</small>{{/if}}</button>{{/each}}</div>
                <div class="rg-outside rg-outside--three">{{#each this.dozens as |spot|}}<button type="button" class="rg-spot {{if spot.selected 'is-selected'}}" disabled={{this.locked}} {{on "click" (fn this.bet spot.key)}}>{{spot.label}}{{#if spot.amount}}<small>{{spot.amount}}</small>{{/if}}</button>{{/each}}</div>
                <div class="rg-outside">{{#each this.outside as |spot|}}<button type="button" class="rg-spot {{spot.color}} {{if spot.selected 'is-selected'}}" disabled={{this.locked}} {{on "click" (fn this.bet spot.key)}}>{{spot.label}}{{#if spot.amount}}<small>{{spot.amount}}</small>{{/if}}</button>{{/each}}</div>
              </div>
            {{else if (eq this.game "scratch")}}
              <div class="rg-scratch-ticket"><div class="rg-ticket-top"><span>RIVERSIDE</span><strong>幸运刮刮乐</strong><small>最高 250 倍</small></div><div class="rg-scratch-area"><div class="rg-scratch-grid">{{#each this.tiles as |tile|}}<span>{{tile.value}}<small>倍</small></span>{{/each}}</div>{{#if (and this.round (not this.revealed))}}<canvas class="rg-scratch-cover" aria-label="刮开票面，或使用下方全部刮开按钮" {{this.scratch this.round.id}}></canvas>{{else unless this.round}}<div class="rg-scratch-placeholder">✦</div>{{/if}}</div><div class="rg-ticket-bottom">{{#if (and this.round (not this.revealed))}}<button type="button" {{on "click" this.reveal}}>全部刮开</button>{{else}}<span>三个相同即中奖</span>{{/if}}</div></div>
            {{else if (eq this.game "blackjack")}}
              <div class="rg-felt"><div class="rg-hand-label">庄家 {{#if this.round}}<span>{{this.round.state.dealer_score}}</span>{{/if}}</div><div class="rg-hand">{{#each this.dealer as |card|}}<div class="rg-playing-card {{if card.hidden 'is-hidden'}} {{if card.red 'is-red'}}">{{#if card.hidden}}<span>R</span>{{else}}<b>{{card.rank}}</b><span>{{card.suit}}</span><b>{{card.rank}}</b>{{/if}}</div>{{/each}}</div><div class="rg-felt-mark"><strong>BLACKJACK</strong><span>3 : 2</span></div><div class="rg-hand">{{#each this.player as |card|}}<div class="rg-playing-card {{if card.red 'is-red'}}"><b>{{card.rank}}</b><span>{{card.suit}}</span><b>{{card.rank}}</b></div>{{/each}}</div><div class="rg-hand-label">你的手牌 {{#if this.round}}<span>{{this.round.state.player_score}}</span>{{/if}}</div></div>
            {{else if (eq this.game "coin")}}
              <div class="rg-coin-scene"><div class="rg-big-coin"><span>RIVERSIDE</span><strong>{{this.coinSide}}</strong><span>RSC</span></div><div class="rg-object-shadow"></div></div>
            {{else if (eq this.game "dice")}}
              <div class="rg-dice-scene"><div class="rg-dice-tray">{{#each this.dice as |die|}}<span class="rg-big-die">{{die.symbol}}</span>{{/each}}</div>{{#if this.round}}<strong class="rg-dice-total">{{this.round.state.total}} 点</strong>{{/if}}</div>
            {{/if}}
            {{#if this.showResult}}<div class="rg-result rg-result--{{this.tone}}" role="status"><span>{{this.outcomeTitle}}</span><strong>{{this.netLabel}}</strong></div>{{/if}}
          </div>
          <aside class="rg-controls">
            <div class="rg-controls-heading"><h2>{{if this.playing "当前牌局" "本轮投入"}}</h2><button type="button" class="rg-icon-button" title="玩法与赔率" aria-label="玩法与赔率" aria-expanded={{this.rules}} {{on "click" this.toggleRules}}>{{dIcon "circle-info"}}</button></div>
            {{#if this.playing}}
              <div class="rg-hand-stake"><strong>{{this.round.stake}}</strong><span>RSC</span></div><div class="rg-blackjack-actions"><button type="button" class="rg-primary" disabled={{this.locked}} {{on "click" (fn this.move "hit")}}>要牌</button><button type="button" class="rg-secondary" disabled={{this.locked}} {{on "click" (fn this.move "stand")}}>停牌</button><button type="button" class="rg-secondary" disabled={{this.doubleDisabled}} {{on "click" (fn this.move "double")}}>加倍 · +{{this.round.stake}} RSC</button></div>
            {{else}}
              <label class="rg-amount-label" for="rg-stake">{{if (eq this.game "roulette") "每次放入" "金额"}}</label><div class="rg-amount"><input id="rg-stake" type="number" inputmode="decimal" min="1" max={{this.maxStake}} step="0.01" value={{this.stake}} disabled={{this.locked}} {{on "input" this.editStake}} /><span>RSC</span></div>
              <div class="rg-chips">{{#each this.chips as |n|}}<button type="button" disabled={{this.locked}} class={{if (eq this.stake (concat n)) "is-selected"}} {{on "click" (fn this.chip n)}}>{{n}}</button>{{/each}}</div>
              {{#if (eq this.game "coin")}}<div class="rg-choices"><button type="button" class={{if (eq this.choice "heads") "is-selected"}} disabled={{this.locked}} aria-pressed={{eq this.choice "heads"}} {{on "click" (fn this.pick "heads")}}>正面</button><button type="button" class={{if (eq this.choice "tails") "is-selected"}} disabled={{this.locked}} aria-pressed={{eq this.choice "tails"}} {{on "click" (fn this.pick "tails")}}>反面</button></div>{{/if}}
              {{#if (eq this.game "dice")}}<div class="rg-choices"><button type="button" class={{if (eq this.choice "small") "is-selected"}} disabled={{this.locked}} aria-pressed={{eq this.choice "small"}} {{on "click" (fn this.pick "small")}}>小<small>4–10</small></button><button type="button" class={{if (eq this.choice "big") "is-selected"}} disabled={{this.locked}} aria-pressed={{eq this.choice "big"}} {{on "click" (fn this.pick "big")}}>大<small>11–17</small></button></div>{{/if}}
              {{#if (eq this.game "roulette")}}<div class="rg-bet-total"><span>合计 {{this.totalLabel}} RSC</span><button type="button" disabled={{this.locked}} {{on "click" this.clearBets}}>清空</button></div>{{/if}}
              <button type="button" class="rg-primary rg-play" disabled={{this.startDisabled}} {{on "click" this.play}}>{{#if this.busy}}处理中…{{else if this.pending}}重试同一请求{{else}}{{if (eq this.game "scratch") "购买" "开始"}} · {{this.totalLabel}} RSC{{/if}}</button>
            {{/if}}
            {{#if this.rules}}<div class="rg-rules">{{#each this.rulesLines as |line|}}<p>{{line}}</p>{{/each}}<p>返还倍数包含本金。所有金额均为社区娱乐积分 RSC。每局基础投入 1–{{this.maxStake}} RSC，二十一点加倍最多为基础投入的两倍。</p></div>{{/if}}
          </aside>
        </div>
      {{/unless}}
      {{#if this.showHistory}}<section class="rg-history"><div class="rg-history-heading"><h2>我的记录</h2><button type="button" class="rg-icon-button" aria-label="关闭记录" {{on "click" this.toggleHistory}}>{{dIcon "xmark"}}</button></div>{{#if this.history.length}}<div class="rg-history-table"><div class="rg-history-labels"><span>游戏 / 时间</span><span>投入</span><span>净收益</span></div>{{#each this.rows key="id" as |row|}}<button type="button" class="rg-history-row" disabled={{this.locked}} {{on "click" (fn this.inspect row)}}><span><strong>{{row.name}}</strong><small>{{row.time}}</small></span><span>{{row.stake}}</span><strong class="rg-{{row.tone}}">{{row.netLabel}}</strong></button>{{/each}}</div>{{#if this.cursor}}<button type="button" class="rg-secondary rg-more" disabled={{this.loading}} {{on "click" this.more}}>更早记录</button>{{/if}}{{else}}<div class="rg-empty">还没有游戏记录</div>{{/if}}</section>{{/if}}
    </section>
  </template>
}
