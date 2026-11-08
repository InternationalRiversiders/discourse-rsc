import Component from "@glimmer/component";
import { LinkTo } from "@ember/routing";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn, concat } from "@ember/helper";
import { modifier } from "ember-modifier";
import { eq, and, not, or } from "truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import RscGameRanking from "./rsc-game-ranking";
import RscGameArt from "./rsc-game-art";
import RscScratchCard from "./rsc-scratch-card";
import RscRouletteWheel from "./rsc-roulette-wheel";
import { animateGame } from "../lib/game-motion";
import { createGameScene, prefetchThree, supports3d } from "../lib/game-3d";
import { formatDateTime } from "../lib/campus-time";

const GAMES=[
  {id:"slots",name:"转转乐",mark:"01",color:"violet"},
  {id:"roulette",name:"幸运转盘",mark:"02",color:"green"},
  {id:"scratch",name:"刮刮乐",mark:"03",color:"gold"},
  {id:"blackjack",name:"21点",mark:"04",color:"blue"},
  {id:"coin",name:"抛硬币",mark:"05",color:"rose"},
  {id:"dice",name:"猜骰子",mark:"06",color:"teal"},
];
const SYMBOLS={cherry:"🍒",lemon:"🍋",bell:"🔔",clover:"🍀",diamond:"💎",seven:"7"};
const SYMBOL_NAMES={cherry:"樱桃",lemon:"柠檬",bell:"铃铛",clover:"四叶草",diamond:"钻石",seven:"7"};
const RED=[1,3,5,7,9,12,14,16,18,19,21,23,25,27,30,32,34,36];
const RULES={
  slots:["每轴 6 种图案，独立且等概率。任意两个相同返还 1.5 倍；三个相同时按下表返还，不叠加。","🍒 2 倍 · 🍋 3 倍 · 🔔 5 倍 · 🍀 7 倍 · 💎 20 倍 · 7 40 倍"],
  roulette:["单零轮盘，0–36 共 37 个数字等概率。点击投注格放入当前金额，可同时选多个位置。","单号 36 倍；每列为间隔 3 的 12 个数字，三个区间各含 12 个数字，均返还 3 倍；红黑、单双、大小 2 倍。开出 0 时，单号 0 返还 36 倍；红黑、单双、大小退回一半本金，列和区间不返还。"],
  scratch:["一张大卡含 10 个独立开奖位。输入金额为整张价格，每个位点按总价的 1/10 计算返还，奖金累加。购票即结算，刮开与刷新不改变结果。","0 倍 50% · 1 倍 20% · 2 倍 27% · 5 倍 2.4% · 10 倍 0.5% · 50 倍 0.09% · 250 倍 0.01%"],
  blackjack:["每局重新洗入 6 副牌。A 算 1 或 11，J/Q/K 算 10。比庄家更接近 21 点获胜，超过 21 点即输。","庄家不足 17 点必须要牌，达到 17 点就停牌。软 17 点是把 A 算作 11 后合计 17 点，例如 A＋6；庄家这种情况也停牌。","天然 21 点指开局两张牌为 A＋10/J/Q/K。双方都是天然 21 点时退还本金，否则天然 21 点胜过普通 21 点，获胜返还 2.5 倍；普通胜利返还 2 倍，平局退还本金。","前两张牌可加倍：追加同额投入，只再取一张牌。不设分牌、保险和投降。断线后可继续原牌局。"],
  coin:["正面银杏叶、反面纸船，各 50% 概率。猜中返还 2 倍，猜错不返还，不抽成。"],
  dice:["三颗公平六面骰。小为 4–10 点，大为 11–17 点。三个相同为豹子，无论选大小都退回本金。","猜中返还 2 倍。"],
};
const money=(n)=>Number(n||0).toLocaleString("zh-CN",{maximumFractionDigits:3});
// Deal order: player, dealer, player, dealer; later cards arrive one by one.
const card=(n,i,round,dealer)=>{
  const delay=i<2 ? (i*2+(dealer?1:0))*0.14 : dealer ? (i-1)*0.32 : 0;
  const base={key:`${round??"demo"}-${i}`,style:`--rg-deal-delay:${delay}s;--rg-deal-tilt:${((i*37+(dealer?11:0))%9)-4}deg`};
  if(n===null){return {...base,hidden:true};}
  const suits=["♠","♥","♣","♦"],rank=n%13;
  return {...base,rank:["A","2","3","4","5","6","7","8","9","10","J","Q","K"][rank],suit:suits[Math.floor(n/13)],red:[1,3].includes(Math.floor(n/13))};
};
export default class extends Component {
  @tracked lottery=this.args.model.lottery;
  @tracked game=null;
  @tracked balance=this.args.model.balance;
  @tracked history=this.args.model.history||[];
  @tracked historyPage=this.args.model.history_page||1;
  @tracked historyPages=this.args.model.history_pages||1;
  @tracked historyTotal=this.args.model.history_total||0;
  @tracked pageInput=String(this.args.model.history_page||1);
  @tracked historyError="";
  @tracked active=this.args.model.active;
  @tracked walletStatus=this.args.model.wallet_status;
  @tracked readOnly=this.args.model.read_only;
  @tracked round=null;
  @tracked stake="10";
  @tracked choice="heads";
  @tracked bets={};
  @tracked betMode="add";
  @tracked betUndo=[];
  @tracked inspected=this.args.model.selected_round||null;
  @tracked busy=false;
  @tracked animating=false;
  @tracked loading=false;
  @tracked pending=null;
  @tracked error="";
  @tracked rules=false;
  @tracked showHistory=!!this.args.model.selected_round;
  @tracked revealed=false;
  @tracked scene3d=null;
  pending3d=null;
  scenePromise=null;
  sceneCtl=null;
  games=GAMES;
  constructor(){super(...arguments);prefetchThree();}
  chips=[5,10,25,50];
  get lotteryPool(){return money(this.lottery?.pool);}
  get selectedGame(){return this.game ? [this.game] : [];}
  get name(){return GAMES.find(g=>g.id===this.game)?.name;}
  get rulesLines(){return RULES[this.game]||[];}
  get largeScratch(){return !this.round||Array.isArray(this.round.state.spots);}
  get maxStake(){return this.args.model.max_stake;}
  get balanceLabel(){return money(this.balance);}
  get blocked(){return this.busy||this.animating||this.readOnly||this.walletStatus!=="active";}
  get locked(){return this.blocked||!!this.pending;}
  get playing(){return this.round?.game==="blackjack"&&this.round?.status==="playing";}
  get total(){return this.game==="roulette" ? Object.values(this.bets).reduce((a,b)=>a+Math.round(b*100),0)/100 : Number(this.stake)||0;}
  get totalLabel(){return money(this.total);}
  get startDisabled(){return this.blocked||this.playing||(!this.pending&&(!Number.isFinite(this.total)||this.total<0.01||Math.abs(this.total*100-Math.round(this.total*100))>1e-8||this.total>this.maxStake||this.total>Number(this.balance)));}
  get doubleDisabled(){return this.blocked||!!this.pending||!this.round?.state.can_double||Number(this.balance)<Number(this.round?.stake);}
  get netLabel(){const n=Number(this.round?.net);return `${n>0?"+":""}${money(n)} RSC`;}
  get tone(){return Number(this.round?.net)>0?"win":Number(this.round?.net)<0?"loss":"push";}
  get outcomeTitle(){if(this.round?.state.result==="push"){return this.game==="dice"?"豹子 · 退回本金":this.game==="blackjack"?"平局 · 退回本金":"回本";}if(this.game==="roulette"&&Number(this.round?.net)<0&&Number(this.round?.payout)>0){return "部分返还";}return {win:"获胜",lose:"未中奖",push:"平局",bust:"爆牌",blackjack:"天生 21"}[this.round?.state.result]||"";}
  get showResult(){return !this.animating&&!this.pending&&this.round?.status==="settled"&&(this.game!=="scratch"||(this.revealed&&!this.largeScratch));}
  get reels(){return (this.round?.state.symbols||["seven","seven","seven"]).map((x,i)=>({key:i,strip:this.animating ? [...Array.from({length:18+i*6},(_,j)=>SYMBOLS[Object.keys(SYMBOLS)[(j+i)%6]]),SYMBOLS[x]] : [SYMBOLS[x]]}));}
  get dice(){return (this.round?.state.dice||[1,3,5]).map((value,i)=>{const [x,y]=[[0,0],[-90,0],[0,-90],[0,90],[90,0],[0,180]][value-1];return {key:i,value,x,y,style:`transform: rotateX(${x}deg) rotateY(${y}deg)`};});}
  get dieFaces(){return [[1,[4]],[2,[0,8]],[3,[0,4,8]],[4,[0,2,6,8]],[5,[0,2,4,6,8]],[6,[0,2,3,5,6,8]]].map(([n,pips])=>({n,pips:Array.from({length:9},(_,i)=>({i,visible:pips.includes(i)}))}));}
  get uses3d(){return this.scene3d===this.game;}
  get sceneLabel(){
    const state=this.round?.state;
    if(this.animating){return "开奖中";}
    if(!state){return this.name;}
    return {slots:()=>state.symbols?.map(x=>SYMBOL_NAMES[x]).join("、"),roulette:()=>`开奖号码 ${state.number}`,blackjack:()=>`庄家 ${state.dealer_score} 点，你的手牌 ${state.player_score} 点`,coin:()=>state.landed==="tails"?"反面（纸船）":"正面（银杏）",dice:()=>`${state.dice?.join("、")} 点，合计 ${state.total} 点`}[this.game]?.()||this.name;
  }
  get rouletteBadge(){const n=this.round?.state?.number;if(this.animating||n===undefined||n===null){return null;}return {n,color:n===0?"zero":RED.includes(n)?"red":"black"};}
  view3d = modifier((host,[game])=>{
    if(!supports3d(game)){this.scenePromise=null;return;}
    let alive=true,ctl=null;
    const promise=this.scenePromise=createGameScene(game,host).then(c=>{
      if(!alive||this.isDestroying||this.isDestroyed){c.dispose();return null;}
      ctl=this.sceneCtl=c;c.show(this.round?.game===game?this.round:null);
      if(this.animating){this.pending3d=game;}else{this.scene3d=game;}
      return c;
    }).catch(()=>null);
    return()=>{
      alive=false;ctl?.dispose();
      if(this.sceneCtl===ctl){this.sceneCtl=null;}
      if(this.scenePromise===promise){this.scenePromise=null;}
      // Tracked state is never written during teardown; drop the flag on the next tick.
      Promise.resolve().then(()=>{if(!this.isDestroying&&!this.isDestroyed&&this.scene3d===game&&!this.sceneCtl){this.scene3d=null;}});
    };
  });
  get coinStyle(){return `transform: rotateY(${this.round?.state.landed==="tails"?180:0}deg)`;}
  motion = modifier((stage,[id,playing])=>{
    if(!id||!playing){stage.dataset.wheelAngle=stage.querySelector(".rg-wheel-disc")?.dataset.angle||"0";if(this.round?.game===this.game){this.sceneCtl?.show(this.round);}return;}
    const game=this.game;
    return animateGame(stage,this.round,()=>{if(!this.isDestroying&&!this.isDestroyed){this.animating=false;if(this.pending3d===game&&this.sceneCtl){this.scene3d=game;}this.pending3d=null;}},{scene:this.scenePromise,onScene:()=>{this.scene3d=game;this.pending3d=null;}});
  });
  get player(){return (this.round?.state.player||[0,22]).map((n,i)=>card(n,i,this.round?.id,false));}
  get dealer(){return (this.round?.state.dealer||[11,null]).map((n,i)=>card(n,i,this.round?.id,true));}
  get tiles(){
    const values=this.round?.state.tiles||[1,2,5,10,50,250,1,2,5];
    const counts=values.reduce((m,x)=>({...m,[x]:(m[x]||0)+1}),{});
    const lucky=this.round&&this.revealed&&Number(this.round.net)>0 ? Object.keys(counts).find(x=>counts[x]>=3) : null;
    return values.map((x,i)=>({key:i,value:x,lucky:lucky!==null&&lucky!==undefined&&String(x)===lucky,style:`--rg-tile:${i}`}));
  }
  get coinSide(){return this.round?.state.landed==="tails"?"反":"正";}
  get numberRows(){return [3,2,1].map(start=>Array.from({length:12},(_,i)=>start+i*3).map(n=>this.spot(`n${n}`,n,RED.includes(n)?"red":"black")));}
  get zero(){return this.spot("n0","0","zero");}
  get outside(){return [["low","1–18"],["even","双"],["red","红"],["black","黑"],["odd","单"],["high","19–36"]].map(([key,label])=>this.spot(key,label,key));}
  get dozens(){return [["dozen1","1–12"],["dozen2","13–24"],["dozen3","25–36"]].map(([key,label])=>this.spot(key,label));}
  get columns(){return [1,2,3].map(n=>({...this.spot(`column${n}`,`第 ${n} 列`),numbers:Array.from({length:12},(_,i)=>n+i*3).join("、")}));}
  get rows(){return this.history.map(r=>({...r,expanded:r.id===this.inspected?.id,name:GAMES.find(g=>g.id===r.game)?.name||r.name,time:formatDateTime(r.created_at),netLabel:r.net===null?"进行中":`${Number(r.net)>0?"+":""}${money(r.net)}`,tone:Number(r.net)>0?"win":Number(r.net)<0?"loss":"push"}));}
  spot(key,label,color=""){return {key,label,color,amount:this.bets[key]?money(this.bets[key]):null,selected:!!this.bets[key]};}
  @action open(id){if(this.busy||this.animating||this.pending){return;} this.game=id;this.round=id==="blackjack"?this.active:null;this.choice=id==="dice"?"small":"heads";this.rules=false;this.error="";this.revealed=false;}
  @action back(){if(!this.busy&&!this.animating&&!this.pending){this.game=null;this.rules=false;this.error="";this.showHistory=false;}}
  @action editStake(e){this.stake=e.target.value;}
  @action chip(n){if(!this.locked){this.stake=String(n);}}
  @action pick(choice){if(!this.locked){this.choice=choice;}}
  @action setBetMode(mode){if(!this.locked){this.betMode=mode;this.error="";}}
  @action bet(key){
    if(this.locked){return;}
    const amount=Number(this.stake),subtract=this.betMode==="subtract";
    if(!Number.isFinite(amount)||amount<0.01||Math.abs(amount*100-Math.round(amount*100))>1e-8||(!subtract&&Math.round(this.total*100)+Math.round(amount*100)>Math.floor(Math.min(this.maxStake,Number(this.balance))*100+1e-8))){this.error="请检查投入金额和可用余额。";return;}
    this.error="";
    if(subtract&&!this.bets[key]){return;}
    this.betUndo=[...this.betUndo,this.bets];
    const next={...this.bets},value=Math.max(0,Math.round(((next[key]||0)+(subtract?-amount:amount))*100)/100);
    if(value){next[key]=value;}else{delete next[key];}
    this.bets=next;
  }
  @action undoBet(){if(!this.locked&&this.betUndo.length){this.bets=this.betUndo.at(-1);this.betUndo=this.betUndo.slice(0,-1);this.error="";}}
  @action clearBets(){if(!this.locked&&this.total){this.betUndo=[...this.betUndo,this.bets];this.bets={};this.error="";}}
  get record(){return this.inspected;}
  get viewingLinkedHistory(){return !!this.args.model.selected_round&&this.showHistory;}
  get previousDisabled(){return this.loading||this.historyPage<=1;}
  get nextDisabled(){return this.loading||this.historyPage>=this.historyPages;}
  get recordHands(){
    const r=this.record,s=r?.state;
    if(r?.game!=="blackjack"||!s){return [];}
    return [{label:"你的手牌",cards:s.player,score:s.player_score},{label:"庄家",cards:s.dealer,score:s.dealer_score}].map(h=>({...h,cards:(h.cards||[]).map((n,i)=>card(n,i,r.id,false)),scoreLabel:h.cards?.includes(null)?`明牌 ${h.score} 点`:`${h.score} 点`}));
  }
  get recordResult(){
    const r=this.record,s=r?.state;if(!s){return "";}
    if(r.status==="playing"){return "牌局进行中，可返回游戏继续";}
    switch(r.game){
      case "roulette": return `开奖号码 ${s.number}`;
      case "slots": return (s.symbols||[]).map(x=>SYMBOL_NAMES[x]).join(" · ");
      case "coin": return s.landed==="tails"?"反面（纸船）":"正面（银杏）";
      case "dice": return `${s.dice?.join("、")} 点，合计 ${s.total} 点`;
      case "blackjack": return `你的手牌 ${s.player_score} 点 · 庄家 ${s.dealer_score} 点`;
      case "scratch": return s.spots?`各位点倍数：${s.spots.map(x=>typeof x==="object"?x.multiplier:x).join("、")}`:`票面：${s.tiles?.join("、")}`;
    }
    return "";
  }
  get recordBets(){
    const s=this.record?.state;if(!s){return "";}
    const labels={heads:"正面",tails:"反面",small:"小",big:"大",red:"红",black:"黑",odd:"单",even:"双",low:"1–18",high:"19–36",dozen1:"1–12",dozen2:"13–24",dozen3:"25–36",column1:"第 1 列",column2:"第 2 列",column3:"第 3 列"};
    if(s.bets?.length){return s.bets.map(b=>`${labels[b.choice]||b.choice.replace(/^n/,"")}：${b.stake} RSC`).join(" · ");}
    return ["coin","dice"].includes(this.record.game)?labels[s.choice]||"":"";
  }
  @action toggleRules(){this.rules=!this.rules;}
  @action toggleHistory(){this.showHistory=!this.showHistory;if(this.showHistory){this.loadHistoryPage(this.historyPage);}}
  @action reveal(){this.revealed=true;}
  @action inspect(r){if(this.busy||this.animating||this.pending){return;}this.inspected=this.inspected?.id===r.id?null:r;this.historyError="";}
  @action async refresh(){
    if(this.loading||this.busy||this.animating){return;} this.loading=true;
    try{const data=await ajax("/rsc/games/state.json",{data:{page:this.historyPage}});if(this.isDestroying||this.isDestroyed){return;}this.lottery=data.lottery;this.balance=data.balance;this.setHistory(data);this.active=data.active;this.walletStatus=data.wallet_status;this.readOnly=data.read_only;if(this.game==="blackjack"){this.round=data.active||data.history.find(r=>r.id===this.round?.id)||null;}}
    catch(e){if(!this.isDestroying&&!this.isDestroyed){this.error=extractError(e);}}
    finally{if(!this.isDestroying&&!this.isDestroyed){this.loading=false;}}
  }
  setHistory(data){
    this.history=data.history;this.historyPage=data.history_page;this.historyPages=data.history_pages;this.historyTotal=data.history_total;this.pageInput=String(data.history_page);
    if(this.inspected){this.inspected=data.history.find(r=>r.id===this.inspected.id)||null;}
  }
  async loadHistoryPage(page){
    if(this.loading){return;}this.loading=true;this.historyError="";
    try{const data=await ajax("/rsc/games/state.json",{data:{page}});if(!this.isDestroying&&!this.isDestroyed){this.setHistory(data);}}
    catch(e){if(!this.isDestroying&&!this.isDestroyed){this.historyError=extractError(e);}}
    finally{if(!this.isDestroying&&!this.isDestroyed){this.loading=false;}}
  }
  @action previousPage(){if(!this.previousDisabled){this.loadHistoryPage(this.historyPage-1);}}
  @action nextPage(){if(!this.nextDisabled){this.loadHistoryPage(this.historyPage+1);}}
  @action editPage(e){this.pageInput=e.target.value;}
  @action jumpPage(e){e.preventDefault();const n=Number(this.pageInput);if(Number.isInteger(n)&&n>=1&&n<=this.historyPages){this.loadHistoryPage(n);}else{this.historyError=`请输入 1–${this.historyPages} 之间的页码。`;}}
  @action play(){if(this.startDisabled){return;} if(this.pending){return this.send(this.pending);}const data={game:this.game,stake:this.stake,choice:["coin","dice"].includes(this.game)?this.choice:null,bets:Object.entries(this.bets).map(([choice,stake])=>({choice,stake:String(stake)})),request_id:crypto.randomUUID()};return this.send({url:"/rsc/games/play.json",data});}
  @action move(move){if(this.blocked||this.pending){return;}return this.send({url:`/rsc/games/${this.round.id}/action.json`,data:{move,version:this.round.version,request_id:crypto.randomUUID()}});}
  @action retry(){if(this.pending&&!this.busy){return this.send(this.pending);}}
  async send(request){
    this.busy=true;this.error="";this.pending=request;
    try{
      const result=await ajax(request.url,{type:"POST",contentType:"application/json",data:JSON.stringify(request.data)});
      if(this.isDestroying||this.isDestroyed){return;}
      this.animating=["roulette","slots","coin","dice","blackjack"].includes(result.game);this.round=result;this.balance=result.balance;this.pending=null;this.revealed=false;this.betUndo=[];
      if(result.game==="blackjack"){this.active=result.status==="playing"?result:null;}
      if(this.historyPage===1){this.history=[result,...this.history.filter(r=>r.id!==result.id)].slice(0,20);}
      if(request.url==="/rsc/games/play.json"&&!result.replayed){this.historyTotal++;this.historyPages=Math.max(1,Math.ceil(this.historyTotal/20));}
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
      {{#if this.game}}<header class="rg-topbar">
        <div class="rg-brand"><button type="button" class="rg-icon-button" title="返回游戏" aria-label="返回游戏" disabled={{this.locked}} {{on "click" this.back}}>{{dIcon "arrow-left"}}</button><h1 title={{this.name}}>{{this.name}}</h1></div>
        <div class="rg-top-actions"><span class="rg-balance">{{dIcon "coins"}}<strong>{{this.balanceLabel}}</strong><small>RSC</small></span><button type="button" class="rg-icon-button" title="刷新余额" aria-label="刷新余额" disabled={{this.busy}} {{on "click" this.refresh}}>{{dIcon "arrows-rotate"}}</button><button type="button" class="rg-icon-button" title="我的记录" aria-label="我的记录" aria-expanded={{this.showHistory}} {{on "click" this.toggleHistory}}>{{dIcon "clock-rotate-left"}}</button></div>
      </header>{{/if}}
      {{#if this.error}}<div class="rg-error" role="alert">{{this.error}}{{#if this.pending}}<button type="button" disabled={{this.busy}} {{on "click" this.retry}}>重试同一请求</button>{{else}}<button type="button" disabled={{this.busy}} {{on "click" this.refresh}}>刷新</button>{{/if}}</div>{{/if}}
      {{#if this.readOnly}}<div class="rg-notice">游戏暂时维护中</div>{{else if (not (eq this.walletStatus "active"))}}<div class="rg-notice">钱包已冻结，暂不能参与游戏</div>{{/if}}

      {{#unless this.viewingLinkedHistory}}
      {{#unless this.game}}
        {{#if this.lottery}}<LinkTo @route="rsc-lottery" class="rl-banner rh-banner"><span class="rl-banner-title rh-banner-title"><small>RIVERSIDE</small><strong>大乐透</strong><span>每日 20:00 开奖 · 北京时间</span></span><span class="rl-banner-pool rh-banner-metric"><small>当前奖池</small><strong>{{this.lotteryPool}} <small>RSC</small></strong></span><span class="rl-banner-cta rh-banner-cta">去选号 →</span></LinkTo>{{/if}}
        {{#if this.active}}<button type="button" class="rg-resume" {{on "click" (fn this.open "blackjack")}}><span>♠</span>继续21点<strong>返回牌局 →</strong></button>{{/if}}
        <div class="rg-lobby">{{#each this.games as |game|}}<button type="button" class="rg-game-card rg-game-card--{{game.color}}" {{on "click" (fn this.open game.id)}}><span class="rg-card-number">{{game.mark}}</span><RscGameArt @game={{game.id}} /><div class="rg-card-bottom"><h2>{{game.name}}</h2><span class="rg-card-arrow">↗</span></div></button>{{/each}}</div>
      {{else}}
        <nav class="rg-tabs" aria-label="选择游戏">{{#each this.games as |game|}}<button type="button" class={{if (eq this.game game.id) "is-selected"}} disabled={{this.locked}} aria-pressed={{eq this.game game.id}} {{on "click" (fn this.open game.id)}}>{{game.name}}</button>{{/each}}</nav>
        <div class="rg-play-layout">
          <div class="rg-stage rg-stage--{{this.game}} {{if this.busy 'is-busy'}} {{if this.uses3d 'is-3d'}} {{if this.animating 'is-animating'}}" aria-busy={{or this.busy this.animating}} {{this.motion this.round.id this.animating}}>
            {{#if (eq this.game "slots")}}
              <div class="rg-slot-machine"><div class="rg-slot-top"><span>RIVERSIDE</span><span>★ ★ ★</span></div><div class="rg-reels">{{#each this.reels as |reel|}}<div class="rg-reel"><div class="rg-reel-strip">{{#each reel.strip as |symbol|}}<span>{{symbol}}</span>{{/each}}</div></div>{{/each}}</div><div class="rg-3d rg-3d--slots" role="img" aria-label={{this.sceneLabel}} {{this.view3d "slots"}}></div><div class="rg-slot-base"><span>● ● ●</span><strong>777</strong></div></div>
            {{else if (eq this.game "roulette")}}
              <RscRouletteWheel @number={{this.round.state.number}} @hasRound={{this.round}} @spinning={{this.animating}} />
              <div class="rg-3d-wrap rg-3d-wrap--roulette"><div class="rg-3d rg-3d--roulette" role="img" aria-label={{this.sceneLabel}} {{this.view3d "roulette"}}></div>{{#if this.rouletteBadge}}<span class="rg-3d-badge rg-3d-badge--{{this.rouletteBadge.color}}">{{this.rouletteBadge.n}}</span>{{/if}}</div>
              <div class="rg-bet-toolbar" aria-label="调整投注"><button type="button" class={{if (eq this.betMode "add") "is-selected"}} aria-pressed={{eq this.betMode "add"}} disabled={{this.locked}} {{on "click" (fn this.setBetMode "add")}}>＋ 加注</button><button type="button" class={{if (eq this.betMode "subtract") "is-selected"}} aria-pressed={{eq this.betMode "subtract"}} disabled={{this.locked}} {{on "click" (fn this.setBetMode "subtract")}}>− 减注</button><button type="button" disabled={{or this.locked (not this.betUndo.length)}} {{on "click" this.undoBet}}>撤销</button><button type="button" disabled={{or this.locked (not this.total)}} {{on "click" this.clearBets}}>清空</button><span>每次 {{if (eq this.betMode "subtract") "−" "+"}}{{this.stake}} RSC</span></div>
              <div class="rg-betting-board">
                <button type="button" class="rg-spot zero {{if this.zero.selected 'is-selected'}}" disabled={{this.locked}} {{on "click" (fn this.bet "n0")}}>0{{#if this.zero.amount}}<small>{{this.zero.amount}}</small>{{/if}}</button>
                <div class="rg-number-board">{{#each this.numberRows as |row|}}{{#each row as |spot|}}<button type="button" class="rg-spot {{spot.color}} {{if spot.selected 'is-selected'}}" disabled={{this.locked}} {{on "click" (fn this.bet spot.key)}}>{{spot.label}}{{#if spot.amount}}<small>{{spot.amount}}</small>{{/if}}</button>{{/each}}{{/each}}</div>
                <div class="rg-outside rg-outside--three rg-column-bets">{{#each this.columns as |spot|}}<button type="button" class="rg-spot {{if spot.selected 'is-selected'}}" title={{spot.numbers}} disabled={{this.locked}} {{on "click" (fn this.bet spot.key)}}>{{spot.label}}{{#if spot.amount}}<small>{{spot.amount}}</small>{{/if}}</button>{{/each}}</div>
                <div class="rg-outside rg-outside--three">{{#each this.dozens as |spot|}}<button type="button" class="rg-spot {{if spot.selected 'is-selected'}}" disabled={{this.locked}} {{on "click" (fn this.bet spot.key)}}>{{spot.label}}{{#if spot.amount}}<small>{{spot.amount}}</small>{{/if}}</button>{{/each}}</div>
                <div class="rg-outside">{{#each this.outside as |spot|}}<button type="button" class="rg-spot {{spot.color}} {{if spot.selected 'is-selected'}}" disabled={{this.locked}} {{on "click" (fn this.bet spot.key)}}>{{spot.label}}{{#if spot.amount}}<small>{{spot.amount}}</small>{{/if}}</button>{{/each}}</div>
              </div>
            {{else if (eq this.game "scratch")}}
              {{#if this.largeScratch}}<RscScratchCard @round={{this.round}} @price={{this.stake}} @onReveal={{this.reveal}} @revealed={{this.revealed}} />{{else}}
              <div class="rg-scratch-ticket"><div class="rg-ticket-top"><span>RIVERSIDE</span><strong>刮刮乐</strong><small>最高 250 倍</small></div><div class="rg-scratch-area"><div class="rg-scratch-grid">{{#each this.tiles as |tile|}}<span class={{if tile.lucky "is-lucky"}} style={{tile.style}}>{{tile.value}}<small>倍</small></span>{{/each}}</div>{{#if (and this.round (not this.revealed))}}<canvas class="rg-scratch-cover" aria-label="刮开票面，或使用下方全部刮开按钮" {{this.scratch this.round.id}}></canvas>{{else unless this.round}}<div class="rg-scratch-placeholder">✦</div>{{/if}}</div><div class="rg-ticket-bottom">{{#if (and this.round (not this.revealed))}}<button type="button" {{on "click" this.reveal}}>全部刮开</button>{{else}}<span>三个相同即中奖</span>{{/if}}</div></div>
              {{/if}}
            {{else if (eq this.game "blackjack")}}
              <div class="rg-felt"><div class="rg-hand-label">庄家 {{#if this.round}}<span>{{this.round.state.dealer_score}}</span>{{/if}}</div><div class="rg-3d rg-3d--blackjack" role="img" aria-label={{this.sceneLabel}} {{this.view3d "blackjack"}}></div><div class="rg-hand rg-hand--dealer">{{#each this.dealer key="key" as |card|}}<div class="rg-playing-card {{if card.hidden 'is-hidden'}} {{if card.red 'is-red'}}" style={{card.style}}><div class="rg-card-inner"><div class="rg-card-face">{{#unless card.hidden}}<b>{{card.rank}}</b><span>{{card.suit}}</span><b>{{card.rank}}</b>{{/unless}}</div><div class="rg-card-back"><span>R</span></div></div></div>{{/each}}</div><div class="rg-hand rg-hand--player">{{#each this.player key="key" as |card|}}<div class="rg-playing-card {{if card.red 'is-red'}}" style={{card.style}}><div class="rg-card-inner"><div class="rg-card-face"><b>{{card.rank}}</b><span>{{card.suit}}</span><b>{{card.rank}}</b></div><div class="rg-card-back"><span>R</span></div></div></div>{{/each}}</div><div class="rg-hand-label">你的手牌 {{#if this.round}}<span>{{this.round.state.player_score}}</span>{{/if}}</div></div>
            {{else if (eq this.game "coin")}}
              <div class="rg-3d rg-3d--coin" role="img" aria-label={{this.sceneLabel}} {{this.view3d "coin"}}></div><div class="rg-coin-scene"><div class="rg-coin-flipper" style={{this.coinStyle}}><div class="rg-big-coin rg-coin-front"><span>RIVERSIDE</span><svg class="rg-coin-emblem" viewBox="-300 -300 600 600" aria-hidden="true"><path d="M0 95C-120 40-265-40-270-130C-215-205-120-250-40-235Q-12-185 0-150Q12-185 40-235C120-250 215-205 270-130C265-40 120 40 0 95ZM0 90C4 170 30 230 70 270" /></svg><span>RSC</span></div><div class="rg-big-coin rg-coin-back"><span>RIVERSIDE</span><svg class="rg-coin-emblem" viewBox="-320 -300 640 620" aria-hidden="true"><path d="M-300 40H300L200 175H-200ZM-150 40L10-275L150 40ZM-300 40L-205-55L-150 40M300 40L205-55L150 40M10-275L0 40M-260 240Q-170 210-80 240T100 240T280 240" /></svg><span>RSC</span></div></div><div class="rg-object-shadow"></div></div>
            {{else if (eq this.game "dice")}}
              <div class="rg-dice-scene"><div class="rg-3d rg-3d--dice" role="img" aria-label={{this.sceneLabel}} {{this.view3d "dice"}}></div><div class="rg-dice-tray">{{#each this.dice as |die|}}<div class="rg-die-space" role="img" aria-label={{if this.animating "骰子翻滚中" (concat die.value " 点")}}><div class="rg-die-cube" style={{die.style}} data-x={{die.x}} data-y={{die.y}}>{{#each this.dieFaces as |face|}}<div class="rg-die-face rg-die-face--{{face.n}}">{{#each face.pips as |pip|}}<i class={{if pip.visible "is-pip"}}></i>{{/each}}</div>{{/each}}</div></div>{{/each}}</div>{{#if (and this.round (not this.animating))}}<strong class="rg-dice-total">{{this.round.state.total}} 点</strong>{{/if}}</div>
            {{/if}}
            {{#if this.showResult}}<div class="rg-result rg-result--{{this.tone}}" role="status"><span>{{this.outcomeTitle}}</span><strong>{{this.netLabel}}</strong></div>{{/if}}
          </div>
          <aside class="rg-controls">
            <div class="rg-controls-heading"><h2>{{if this.playing "当前牌局" "本轮投入"}}</h2><button type="button" class="rg-icon-button" title="玩法与赔率" aria-label="玩法与赔率" aria-expanded={{if this.rules "true" "false"}} {{on "click" this.toggleRules}}>{{dIcon "circle-info"}}</button></div>
            {{#if this.playing}}
              <div class="rg-hand-stake"><strong>{{this.round.stake}}</strong><span>RSC</span></div><div class="rg-blackjack-actions"><button type="button" class="rg-primary" disabled={{this.locked}} {{on "click" (fn this.move "hit")}}>要牌</button><button type="button" class="rg-secondary" disabled={{this.locked}} {{on "click" (fn this.move "stand")}}>停牌</button><button type="button" class="rg-secondary" disabled={{this.doubleDisabled}} {{on "click" (fn this.move "double")}}>加倍 · +{{this.round.stake}} RSC</button></div>
            {{else}}
              <label class="rg-amount-label" for="rg-stake">{{if (eq this.game "roulette") "每次加减" (if (eq this.game "scratch") "整张价格" "金额")}}</label><div class="rg-amount"><input id="rg-stake" type="number" inputmode="decimal" min="0.01" max={{this.maxStake}} step="0.01" value={{this.stake}} disabled={{this.locked}} {{on "input" this.editStake}} /><span>RSC</span></div>
              <div class="rg-chips">{{#each this.chips as |n|}}<button type="button" disabled={{this.locked}} class={{if (eq this.stake (concat n)) "is-selected"}} {{on "click" (fn this.chip n)}}>{{n}}</button>{{/each}}</div>
              {{#if (eq this.game "coin")}}<div class="rg-choices"><button type="button" class={{if (eq this.choice "heads") "is-selected"}} disabled={{this.locked}} aria-pressed={{eq this.choice "heads"}} {{on "click" (fn this.pick "heads")}}>正面<small>银杏</small></button><button type="button" class={{if (eq this.choice "tails") "is-selected"}} disabled={{this.locked}} aria-pressed={{eq this.choice "tails"}} {{on "click" (fn this.pick "tails")}}>反面<small>纸船</small></button></div>{{/if}}
              {{#if (eq this.game "dice")}}<div class="rg-choices"><button type="button" class={{if (eq this.choice "small") "is-selected"}} disabled={{this.locked}} aria-pressed={{eq this.choice "small"}} {{on "click" (fn this.pick "small")}}>小<small>4–10</small></button><button type="button" class={{if (eq this.choice "big") "is-selected"}} disabled={{this.locked}} aria-pressed={{eq this.choice "big"}} {{on "click" (fn this.pick "big")}}>大<small>11–17</small></button></div>{{/if}}
              {{#if (eq this.game "roulette")}}<div class="rg-bet-total"><span>合计 {{this.totalLabel}} RSC</span><button type="button" disabled={{this.locked}} {{on "click" this.clearBets}}>清空</button></div>{{/if}}
              <button type="button" class="rg-primary rg-play" disabled={{this.startDisabled}} {{on "click" this.play}}>{{#if this.busy}}处理中…{{else if this.animating}}开奖中…{{else if this.pending}}重试同一请求{{else}}{{if (eq this.game "scratch") "购买" "开始"}} · {{this.totalLabel}} RSC{{/if}}</button>
            {{/if}}
            {{#if this.rules}}<div class="rg-rules">{{#each this.rulesLines as |line|}}<p>{{line}}</p>{{/each}}{{#if (eq this.game "roulette")}}<dl class="rg-column-rules">{{#each this.columns as |column|}}<dt>{{column.label}}</dt><dd>{{column.numbers}}</dd>{{/each}}</dl>{{/if}}<p>返还倍数包含本金。所有金额均为社区娱乐积分 RSC。每局基础投入 0.01–{{this.maxStake}} RSC。{{#if (eq this.game "blackjack")}}加倍可追加同额投入。{{/if}}</p></div>{{/if}}
          </aside>
        </div>
        {{#each this.selectedGame key="@identity" as |game|}}<RscGameRanking @game={{game}} />{{/each}}
      {{/unless}}
      {{/unless}}
      {{#if this.showHistory}}<section class="rg-history"><div class="rg-history-heading"><h2>我的记录</h2><button type="button" class="rg-icon-button" aria-label="关闭记录" {{on "click" this.toggleHistory}}>{{dIcon "xmark"}}</button></div>{{#if this.history.length}}<div class="rg-history-table"><div class="rg-history-labels"><span>游戏 / 时间</span><span>投入</span><span>净收益</span></div>{{#each this.rows key="id" as |row|}}<button type="button" class="rg-history-row" aria-expanded={{if row.expanded "true" "false"}} aria-controls="rg-record-{{row.id}}" disabled={{this.locked}} {{on "click" (fn this.inspect row)}}><span><strong>{{row.name}}</strong><small>{{row.time}}</small></span><span>{{row.stake}}</span><strong class="rg-{{row.tone}}">{{row.netLabel}}</strong></button>{{#if row.expanded}}<div id="rg-record-{{row.id}}">{{#if this.record}}<section class="rg-record" aria-label="游戏详情">{{#if this.recordHands.length}}{{#each this.recordHands as |hand|}}<div class="rg-record-hand"><span class="rg-record-label">{{hand.label}}</span><span class="rg-record-cards">{{#each hand.cards key="key" as |c|}}<span class="rg-record-card {{if c.red 'is-red'}} {{if c.hidden 'is-hidden'}}">{{#if c.hidden}}<span aria-label="暗牌">?</span>{{else}}{{c.rank}}{{c.suit}}{{/if}}</span>{{/each}}</span><span>{{hand.scoreLabel}}</span></div>{{/each}}{{else}}{{#if this.recordBets}}<p>投注：{{this.recordBets}}</p>{{/if}}<p>{{this.recordResult}}</p>{{/if}}</section>{{/if}}</div>{{/if}}{{/each}}</div>{{else}}<div class="rg-empty">还没有游戏记录</div>{{/if}}
        {{#if this.historyError}}<p class="rg-history-error" role="alert">{{this.historyError}}</p>{{/if}}
        <form class="rg-history-pagination" aria-label="记录分页" {{on "submit" this.jumpPage}}><span>共 {{this.historyTotal}} 条 · {{this.historyPage}} / {{this.historyPages}}</span><button type="button" disabled={{this.previousDisabled}} {{on "click" this.previousPage}}>上一页</button><button type="button" disabled={{this.nextDisabled}} {{on "click" this.nextPage}}>下一页</button>{{#if (not (eq this.historyPages 1))}}<label>第 <input type="number" aria-label="记录页码" inputmode="numeric" min="1" max={{this.historyPages}} value={{this.pageInput}} disabled={{this.loading}} {{on "input" this.editPage}} /> 页</label><button type="submit" disabled={{this.loading}}>跳转</button>{{/if}}</form>
      </section>{{/if}}
    </section>
  </template>
}
