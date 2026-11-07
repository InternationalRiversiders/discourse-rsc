import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { fn } from "@ember/helper";
import { modifier } from "ember-modifier";
import { eq, not, or } from "truth-helpers";
import { ajax } from "discourse/lib/ajax";
import { extractError } from "discourse/lib/ajax-error";
import ForumUser from "./rsc-user";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import ArcadeArt from "./rsc-arcade-art";
import Core from "../lib/arcade-core";
import Playback from "../lib/arcade-playback";
import draw from "../lib/arcade-draw";
import Effects from "../lib/arcade-effects";
import { loadMergeSprites } from "../lib/arcade-sprites";
import { formatDateTime } from "../lib/campus-time";
const GAMES=[
 {id:'2048',name:'2048',mark:'2048',color:'sand'},
 {id:'blocks',name:'方块堆叠',mark:'▟',color:'lavender'},
 {id:'snake',name:'贪吃蛇',mark:'⌁',color:'mint'},
 {id:'bird',name:'河畔飞鸟',mark:'➤',color:'sky'},
 {id:'hex',name:'六角消除',mark:'⬡',color:'rose'},
 {id:'bricks',name:'打砖块',mark:'▤',color:'peach'},
 {id:'merge',name:'合成大河畔',mark:'🍉',color:'green'}
];
const ENDLESS_RULES={
 '2048':'方向键或滑动合并相同数字，每次合并累加分数。没有步数和倒计时限制，棋盘无法移动时结束。',
 blocks:'左右移动，上键旋转，下键加速，空格落下。消除 1／2／3／4 行获得 100／300／500／800 分；消行越多下落越快，堆到顶部结束。',
 snake:'方向键或滑动转向，吃到食物获得 100 分。不能直接掉头，撞墙、障碍或身体结束，填满可用格子通关。',
 bird:'轻点画面或空格拍动翅膀。每穿过一道障碍获得 1 分，速度和难度随进度逐步增加，碰撞结束。',
 hex:'左右旋转中心六边形，堆叠末尾三个同色块消除并获得 100 分。速度随得分增加，任一边堆到 10 块结束。',
 bricks:'按住左右键或拖动画面移动挡板，每消除一块砖获得 100 分。清屏进入下一关，后续有更耐打的砖块、不同布局和更快球速，3 条生命耗尽结束。',
 merge:'移动指针选择落点，轻点投放；也可左右移动、空格投放。同级图案相碰合成，得分随等级增加。可贴墙投放，越过虚线持续 3 秒结束。'
};
export default class extends Component {
 games=GAMES;
 @tracked rankScope='all';
 @tracked rankInfo=false;
 @action toggleRankInfo(){this.rankInfo=!this.rankInfo;}
 rankChosen=false;
 @tracked game=null;
 @tracked run=null;
 @tracked busy=false;
 @tracked paused=true;
 @tracked error='';
 @tracked ranking=null;
 @tracked rankingError='';
 @tracked score=0;
 @tracked progress=0;
 @tracked pending=null;
 @tracked syncing=false;
 @tracked finishing=false;
 @tracked waiting=false;
 @tracked localOver=false;
 effects=new Effects();repaint=true;mergeSprites=null;
 playback=null;state=null;canvas=null;raf=null;last=0;accumulator=0;generation=0;
 syncPromise=null;saveRequested=false;lastInputAt=0;
 get selected(){return GAMES.find(g=>g.id===this.game);}
 get rulesVersion(){return 2;}
 get rulesText(){return ENDLESS_RULES[this.game];}
 get grid(){return this.game==='2048';}
 get finished(){return this.run?.status==='finished';}
 get inputDisabled(){return this.paused||this.busy||this.finishing||this.finished||this.localOver;}
 get navigationBusy(){return this.busy||this.syncing||!!this.pending;}
 get endLabel(){return this.ranking?.season?.ends_at?formatDateTime(this.ranking.season.ends_at):'';}
 get featured(){return this.args.catalog?.current;}
 get featuredEnd(){return this.featured?formatDateTime(this.featured.ends_at):'';}
 get featuredPrizes(){return this.featured?.prizes?.join(' / ') || '';}
 get rankPrizes(){return this.ranking?.season?.prizes?.join(' / ') || '';}
 get rankRows(){return this.rankScope==='season'?this.ranking?.season?.rows:this.ranking?.rows;}
 get nonSeasonRun(){return this.run&&this.ranking?.season&&this.run.season_id!==this.ranking.season.id;}
 @action selectRank(scope){this.rankScope=scope;this.rankChosen=true;}
 @action openSeason(){if(this.featured){this.open(this.featured.game);this.rankScope='season';}}
 get status(){return this.finished?'成绩已保存':this.error?'连接中断':this.finishing||this.localOver?'保存成绩':this.paused?'已暂停':this.waiting?'等待同步':'挑战中';}
 get startLabel(){return this.finished?'再来一局':this.run?'继续挑战':'开始挑战';}
 get progressLabel(){if(!this.state){return '';}if(this.grid){return `${this.progress} 步`;}if(this.game==='blocks'){return `${this.state.lines} 行`;}if(this.game==='merge'){return `${this.state.drops} 次投放`;}if(this.game==='bricks'){return `第 ${this.state.wave||1} 关`;}if(this.game==='bird'){return `${this.score} 道障碍`;}return '';}
 get controls(){if(this.game==='bird'){return [];}return this.game==='2048'||this.game==='snake'||this.game==='blocks'?['l','u','d','r']:['l','r'];}
 get controlsList(){return this.controls.map(k=>({key:k,label:{l:'←',r:'→',u:'↑',d:'↓'}[k]}));}
 @action async open(game){
  this.generation++;this.rankInfo=false;this.rankChosen=false;this.rankScope=this.featured?.game===game?'season':'all';this.game=game;this.run=null;this.playback=null;this.pending=null;this.error='';
  this.paused=true;this.finishing=false;this.waiting=false;this.localOver=false;this.saveRequested=false;this.ranking=null;
  this.effects=new Effects({reducedMotion:window.matchMedia('(prefers-reduced-motion: reduce)').matches});this.state=Core.create(game,Array(24).fill(3733),this.rulesVersion);this.effects.observe(this.state);this.score=0;this.progress=0;this.loadRanking();
  if(game==='merge'){loadMergeSprites().then(images=>{if(!this.isDestroying){this.mergeSprites=images;this.effects.sprites=images;this.repaint=true;}});}
 }
 @action async back(){
  if(this.busy){return;}this.paused=true;this.playback?.release();await this.flush();
  if(!this.error&&!this.isDestroying){this.game=null;this.playback=null;this.generation++;}
 }
 @action async loadRanking(){const game=this.game;this.rankingError='';try{const r=await ajax('/rsc/arcade/ranking.json',{data:{game},ignoreUnsent:false,timeout:15000});if(this.game===game&&!this.isDestroying){this.ranking=r;this.args.updateSeason?.(r.featured);if(!this.rankChosen){this.rankScope=r.season?'season':'all';}else if(!r.season){this.rankScope='all';}}}catch(e){if(!this.isDestroying){this.rankingError=extractError(e,"网络连接中断，请重试或读取已保存进度。");}}}
 @action async start(){
  if(this.busy||this.syncing||this.pending){return;}
  if(this.run?.status==='playing'&&!this.error){this.paused=false;this.canvas?.focus({preventScroll:true});return;}
  this.busy=true;this.error='';const generation=this.generation;
  try{
   const r=await ajax('/rsc/arcade/start.json',{ignoreUnsent:false,timeout:15000,type:'POST',contentType:'application/json',data:JSON.stringify({game:this.game,request_id:crypto.randomUUID(),rules_version:2,scope:this.rankScope})});
   if(this.isDestroying||generation!==this.generation){return;}
   this.effects=new Effects({reducedMotion:window.matchMedia('(prefers-reduced-motion: reduce)').matches});this.effects.sprites=this.mergeSprites;this.playback=new Playback(r);this.finishing=false;this.saveRequested=false;this.updateView();
   this.paused=r.status!=='playing';this.canvas?.focus({preventScroll:true});
  }catch(e){if(!this.isDestroying){this.error=extractError(e,"网络连接中断，请重试或读取已保存进度。");}}
  finally{if(!this.isDestroying){this.busy=false;}}
 }
 updateView(){
  const p=this.playback;if(!p){return;}
  this.run=p.run;this.state=p.state;this.pending=p.pending;this.score=p.state.score;
  if(this.grid||p.state.tick%15===0||p.state.over){this.progress=p.state.tick;}
  this.waiting=p.blocked&&!p.state.over;this.localOver=p.state.over;this.effects.observe(p.state,p.visualMove);this.repaint=true;
 }
 paint(){if(this.canvas&&this.state){draw(this.canvas,this.state,this.effects);}}
 @action async pause(){this.paused=true;this.playback?.release();await this.flush();}
 @action async finish(){this.paused=true;this.playback?.release();if(this.playback){this.playback.keys=[];}await this.flush(true);}
 @action recover(){
  if(this.busy||this.syncing){return;}
  this.pending=null;this.playback=null;this.run=null;this.finishing=false;this.error='';return this.start();
 }
 @action async retry(){
  if(this.busy||this.syncing){return;}
  if(!this.playback){return this.start();}
  this.error='';await this.flush();
  if(!this.error&&!this.finished&&!this.isDestroying){this.paused=false;}
 }
 flush(finish=false){
  if(!this.playback||this.run.status!=='playing'){return Promise.resolve();}
  if(finish){this.finishing=true;}
  this.saveRequested=true;
  if(this.syncPromise){return this.syncPromise;}
  if(this.busy||this.error){return Promise.resolve();}
  if(!this.playback.pending&&!this.playback.frames&&!this.finishing){this.saveRequested=false;return Promise.resolve();}
  this.syncPromise=this.sendLoop();return this.syncPromise;
 }
 async sendLoop(){
  const p=this.playback;this.syncing=true;
  try{
   while(!this.isDestroying&&p===this.playback&&p.run.status==='playing'){
    if(!p.pending){
     if(!this.saveRequested&&!this.finishing&&!p.needsSync&&!(this.paused&&p.frames)){break;}
     p.checkpoint(crypto.randomUUID(),this.finishing);this.saveRequested=false;
    }
    if(!p.pending){break;}
    this.pending=p.pending;
    const r=await ajax(`/rsc/arcade/${p.run.id}/advance.json`,{ignoreUnsent:false,timeout:15000,type:'POST',contentType:'application/json',data:JSON.stringify({...p.pending,rules_version:2})});
    if(this.isDestroying||p!==this.playback){return;}
    p.acknowledge(r);this.updateView();
    if(r.status!=='playing'){this.paused=true;this.finishing=false;this.loadRanking();break;}
    // Consume queued gestures after a refill, without waiting between moves.
    if(this.grid&&!this.paused){p.advance();this.updateView();}
   }
  }catch(e){
   if(!this.isDestroying){this.error=extractError(e,"网络连接中断，请重试或读取已保存进度。");this.paused=true;p.release();}
  }finally{if(!this.isDestroying){this.syncing=false;this.syncPromise=null;}}
 }
 input(key){
  if(!this.playback||this.inputDisabled||this.error){return;}
  this.lastInputAt=performance.now();this.playback.input(key);if(this.grid){this.advanceFrame();}
 }
 @action press(key,e){
  e?.preventDefault();if(this.inputDisabled){return;}
  e?.currentTarget?.setPointerCapture?.(e.pointerId);
  this.canvas?.focus({preventScroll:true});this.input(key);this.playback?.hold(key);
 }
 @action release(key){this.playback?.release(key);}
 @action keyboardPress(key,e){if(e.detail===0){this.input(key);}}
 @action dropPress(e){this.press(this.game==='bird'?'tap':'drop',e);}
 @action dropKeyboard(e){if(e.detail===0){this.input(this.game==='bird'?'tap':'drop');}}
 advanceFrame(){
  const p=this.playback;if(!p){return;}
  if(p.advance()){this.updateView();}
  if(p.needsSync){this.flush();}
 }
 stage=modifier((canvas)=>{
  this.canvas=canvas;this.paint();let pointer=null;
  const keyMap={ArrowLeft:'l',ArrowRight:'r',ArrowUp:'u',ArrowDown:'d',' ':'drop'};
  const key=e=>{
   const k=keyMap[e.key];if(!k){return;}e.preventDefault();
   if(!e.repeat&&!this.inputDisabled){this.input(this.game==='bird'?'tap':k);this.playback?.hold(k);}
  };
  const up=e=>{const k=keyMap[e.key];if(k){this.playback?.release(k);}};
  const aim=e=>{const r=canvas.getBoundingClientRect();return `x:${Math.round(Math.max(0,Math.min(4000,(e.clientX-r.left)/r.width*4000)))}`;};
  const down=e=>{
   e.preventDefault();canvas.setPointerCapture(e.pointerId);pointer={x:e.clientX,y:e.clientY};canvas.focus({preventScroll:true});
   if(this.game==='bricks'&&this.rulesVersion>=2){this.input(aim(e));}else if(this.game==='merge'){this.input(aim(e));this.input('drop');}
  };
  const playArea=canvas.closest('.ra-play');
  const flap=e=>{if(this.game!=='bird'||this.inputDisabled||e.target.closest('button,a,input,summary,details')){return;}e.preventDefault();canvas.focus({preventScroll:true});this.input('tap');};
  playArea.addEventListener('pointerdown',flap);
  const end=e=>{
   if(pointer&&(this.grid||this.game==='snake')){const dx=e.clientX-pointer.x,dy=e.clientY-pointer.y;if(Math.max(Math.abs(dx),Math.abs(dy))>15){this.input(Math.abs(dx)>Math.abs(dy)?dx>0?'r':'l':dy>0?'d':'u');}}
   pointer=null;
  };
  const cancel=()=>{pointer=null;this.playback?.release();};
  const move=e=>{if(this.game==='merge'||(pointer&&this.game==='bricks'&&this.rulesVersion>=2)){this.input(aim(e));}};
  const blur=()=>{this.pause();};const visibility=()=>{if(document.hidden){this.pause();}};
  canvas.addEventListener('keydown',key);window.addEventListener('keyup',up);canvas.addEventListener('pointerdown',down);canvas.addEventListener('pointerup',end);canvas.addEventListener('pointercancel',cancel);canvas.addEventListener('pointermove',move);window.addEventListener('blur',blur);document.addEventListener('visibilitychange',visibility);
  const loop=t=>{
   if(this.isDestroying){return;}const delta=Math.min(100,t-(this.last||t));this.last=t;
   if(!this.inputDisabled&&!this.error&&this.run?.status==='playing'){
    if(this.grid){this.advanceFrame();if(this.playback.frames&&!this.syncing&&t-this.lastInputAt>=250){this.flush();}}else{
     this.accumulator+=delta;let count=0;
     while(this.accumulator>=1000/60&&count++<6){
      this.advanceFrame();this.accumulator-=1000/60;
      if(this.playback.blocked||this.state.over){this.accumulator=0;break;}
     }
    }
   }else{this.accumulator=0;}
   if(this.repaint||this.effects.active()){this.paint();this.repaint=false;}this.raf=requestAnimationFrame(loop);
  };this.raf=requestAnimationFrame(loop);
  return()=>{playArea.removeEventListener('pointerdown',flap);cancelAnimationFrame(this.raf);canvas.removeEventListener('keydown',key);window.removeEventListener('keyup',up);canvas.removeEventListener('pointerdown',down);canvas.removeEventListener('pointerup',end);canvas.removeEventListener('pointercancel',cancel);canvas.removeEventListener('pointermove',move);window.removeEventListener('blur',blur);document.removeEventListener('visibilitychange',visibility);this.canvas=null;this.playback?.release();};
 });
 <template>
  <section class="ra-app" aria-label="街机区">
   {{#unless this.game}}
    {{#if this.featured}}<button type="button" class="ra-season-banner rh-banner" {{on "click" this.openSeason}}><span class="rh-banner-title"><small>第 {{this.featured.number}} 赛季</small><strong>{{this.featured.name}}</strong><span>{{if (eq this.featured.cadence "daily") "每日轮替" "每周轮替"}} · 截止 {{this.featuredEnd}}</span></span><span class="rh-banner-metric"><small>前五名奖励 · RSC</small><strong>{{if this.featuredPrizes this.featuredPrizes "—"}}</strong></span><span class="rh-banner-cta">去挑战 →</span></button>{{else}}<div class="rh-banner-placeholder">{{#if @catalogError}}{{@catalogError}} <button type="button" class="btn btn-flat" {{on "click" @reloadCatalog}}>重试</button>{{/if}}</div>{{/if}}
    <div class="ra-catalog">{{#each this.games as |game|}}<button type="button" class="ra-card ra-card--{{game.color}}" {{on "click" (fn this.open game.id)}}><div class="ra-card-art" aria-hidden="true"><ArcadeArt @game={{game.id}} />{{#if (eq game.id this.featured.game)}}<span class="ra-featured-tag">本期挑战</span>{{/if}}<i></i><i></i><i></i></div><div class="ra-card-label"><div><h3>{{game.name}}</h3></div><span aria-hidden="true">↗</span></div></button>{{/each}}</div>
   {{else}}
    <header class="ra-heading"><button type="button" class="btn btn-flat" disabled={{or this.busy this.finishing}} {{on "click" this.back}}>← 返回挑战</button><h2>{{this.selected.name}}</h2></header>{{#if this.nonSeasonRun}}<p class="ra-rank-note">本局计入总排行；新开一局可参加当前赛季。</p>{{/if}}
    {{#if this.error}}<div class="rg-error" role="alert">{{this.error}}<button type="button" class="btn" disabled={{or this.busy this.syncing}} {{on "click" this.retry}}>重试并恢复进度</button><button type="button" class="btn btn-flat" disabled={{or this.busy this.syncing}} {{on "click" this.recover}}>读取已保存进度</button></div>{{/if}}
    <div class="ra-layout"><div class="ra-play" data-game={{this.game}}>
     <div class="ra-scorebar"><div><small>本局得分</small><strong>{{this.score}}</strong></div><span role="status">{{if this.run this.status "准备就绪"}}</span><small>{{this.progressLabel}}</small></div>
     <canvas class="ra-canvas" data-game={{this.game}} tabindex="0" role="img" aria-label={{this.selected.name}} {{this.stage}}></canvas>
     <div class="ra-toolbar">{{#if (or this.paused this.finished)}}<button type="button" class="btn btn-primary ra-start" disabled={{this.navigationBusy}} {{on "click" this.start}}>{{this.startLabel}}</button>{{else}}<button type="button" class="btn" disabled={{this.busy}} {{on "click" this.pause}}>暂停并保存</button>{{/if}}{{#if this.run}}{{#unless this.finished}}<button type="button" class="btn btn-flat" disabled={{or this.busy this.finishing}} {{on "click" this.finish}}>结束并保存</button>{{/unless}}{{/if}}</div>
     <div class="ra-controls" data-game={{this.game}}>{{#each this.controlsList as |c|}}<button type="button" aria-label={{c.label}} data-key={{c.key}} disabled={{this.inputDisabled}} {{on "pointerdown" (fn this.press c.key)}} {{on "pointerup" (fn this.release c.key)}} {{on "pointercancel" (fn this.release c.key)}} {{on "lostpointercapture" (fn this.release c.key)}} {{on "click" (fn this.keyboardPress c.key)}}>{{c.label}}</button>{{/each}}{{#if (eq this.game "blocks")}}<button type="button" disabled={{this.inputDisabled}} {{on "pointerdown" this.dropPress}} {{on "click" this.dropKeyboard}}>落下</button>{{/if}}{{#if (eq this.game "merge")}}<button type="button" disabled={{this.inputDisabled}} {{on "pointerdown" this.dropPress}} {{on "click" this.dropKeyboard}}>投放</button>{{/if}}{{#if (eq this.game "bird")}}<button type="button" disabled={{this.inputDisabled}} {{on "pointerdown" this.dropPress}} {{on "click" this.dropKeyboard}}>起飞</button>{{/if}}</div>
     <details class="ra-rules"><summary>玩法与操作</summary><p>{{this.rulesText}}</p><p>允许程序策略，正式成绩以服务器复核为准。后台同步成绩；网络长时间中断时暂停，恢复后继续；存档每次操作后保留 30 天，可暂停后回来继续；赛季结束自动结算已同步的进度，跨期不计入新赛季。</p></details>
    </div><aside class="ra-rank"><div class="ra-rank-heading"><div class="ra-rank-tabs">{{#if this.ranking.season}}<button type="button" class={{if (eq this.rankScope "season") "is-active"}} {{on "click" (fn this.selectRank "season")}}>赛季排行</button>{{/if}}<button type="button" class={{if (eq this.rankScope "all") "is-active"}} {{on "click" (fn this.selectRank "all")}}>总排行</button></div><div class="ra-rank-tools"><button type="button" class="rg-icon-button" aria-label="排行说明" title="排行说明" aria-expanded={{if this.rankInfo "true" "false"}} {{on "click" this.toggleRankInfo}}>{{dIcon "circle-info"}}</button><button type="button" class="rg-icon-button" aria-label="刷新排行" title="刷新排行" {{on "click" this.loadRanking}}>{{dIcon "arrows-rotate"}}</button></div></div>{{#if this.rankInfo}}<div class="rg-rules ra-rank-help"><p>每人取最高分，同分并列。</p>{{#if (eq this.rankScope "season")}}<p>第 {{this.ranking.season.number}} 赛季 · 截止 {{this.endLabel}}</p>{{#if this.rankPrizes}}<p>前五名：{{this.rankPrizes}} RSC</p><p>同分平分所占名次奖金，结束后自动到账。</p>{{else}}<p>本期仅排名，不发放 RSC</p>{{/if}}{{else}}<p>历史最高分永久保留。</p>{{/if}}</div>{{/if}}{{#if this.rankingError}}<p role="alert">{{this.rankingError}}</p>{{/if}}<ol>{{#each this.rankRows as |row|}}<li><span class="ra-place">{{row.rank}}</span><ForumUser @user={{row.user}} /><strong>{{row.score}}</strong></li>{{else}}<li class="ra-empty">还没有成绩，来占个位置。</li>{{/each}}</ol></aside></div>
   {{/unless}}
  </section>
 </template>
}
