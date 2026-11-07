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
import ArcadeArt from "./rsc-arcade-art";
import Core from "../lib/arcade-core";
import Playback from "../lib/arcade-playback";
import draw from "../lib/arcade-draw";
import Effects from "../lib/arcade-effects";
import { loadMergeSprites } from "../lib/arcade-sprites";
import { formatDateTime } from "../lib/campus-time";
const GAMES=[
 {id:'2048',name:'2048',mark:'2048',color:'sand',rules:'方向键或滑动合并相同数字，每次合并累加分数。最多 2,000 步，棋盘无法移动时结束。'},
 {id:'blocks',name:'方块堆叠',mark:'▟',color:'lavender',rules:'左右移动，上键旋转，下键加速，空格落下。单次消除 1／2／3／4 行分别获得 100／300／500／800 分。最多 200 个方块或 5 分钟。'},
 {id:'snake',name:'贪吃蛇',mark:'⌁',color:'mint',rules:'方向键或滑动转向，吃到食物获得 100 分。不能直接掉头，撞墙、障碍或身体结束。最多 5 分钟。'},
 {id:'bird',name:'河畔飞鸟',mark:'➤',color:'sky',rules:'轻点画面或空格拍动翅膀。每穿过一道障碍获得 1 分，碰撞即结束。最多 3 分钟。'},
 {id:'hex',name:'六角消除',mark:'⬡',color:'rose',rules:'左右旋转中心六边形，每条边堆叠的末尾三个同色块消除并获得 100 分。任一边达到 10 块时结束。最多 3 分钟。'},
 {id:'bricks',name:'打砖块',mark:'▤',color:'peach',rules:'按住左右键移动挡板，手机按住屏幕下方方向按钮。每块砖 100 分，共 3 条生命，清空砖块或达到 5 分钟结束。'},
 {id:'merge',name:'合成大河畔',mark:'🍉',color:'green',rules:'移动指针选择落点，轻点投放；也可左右移动、空格投放。同级图案相碰合成，得分随等级增加。越过虚线持续 3 秒则结束，最多 100 次投放或 5 分钟。'}
];
export default class extends Component {
 games=GAMES;
 @tracked catalog=null;
 @tracked catalogError='';
 @tracked rankScope='all';
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
 syncPromise=null;saveRequested=false;
 get selected(){return GAMES.find(g=>g.id===this.game);}
 get grid(){return this.game==='2048';}
 get finished(){return this.run?.status==='finished';}
 get inputDisabled(){return this.paused||this.busy||this.finishing||this.finished||this.localOver;}
 get navigationBusy(){return this.busy||this.syncing||!!this.pending;}
 get endLabel(){return this.ranking?.season?.ends_at?formatDateTime(this.ranking.season.ends_at):'';}
 get featured(){return this.catalog?.current;}
 get featuredEnd(){return this.featured?formatDateTime(this.featured.ends_at):'';}
 get featuredPrizes(){return this.featured?.prizes?.join(' / ') || '';}
 get rankPrizes(){return this.ranking?.season?.prizes?.join(' / ') || '';}
 get rankRows(){return this.rankScope==='season'?this.ranking?.season?.rows:this.ranking?.rows;}
 get nonSeasonRun(){return this.run&&this.ranking?.season&&this.run.season_id!==this.ranking.season.id;}
 @action selectRank(scope){this.rankScope=scope;}
 @action openSeason(){if(this.featured){this.open(this.featured.game);this.rankScope='season';}}
 @action async loadCatalog(){
  try{const r=await ajax('/rsc/arcade/catalog.json',{ignoreUnsent:false,timeout:15000});if(this.isDestroying){return;}
   const changed=this.catalog?.current?.id!==r.current?.id;this.catalog=r;this.catalogError='';if(changed&&this.game){this.loadRanking();}
  }catch(e){if(!this.isDestroying){this.catalogError='赛季信息暂时未能加载';}}
 }
 boot=modifier(()=>{this.loadCatalog();const timer=setInterval(()=>this.loadCatalog(),60000);return()=>clearInterval(timer);});
 get status(){return this.finished?'成绩已保存':this.error?'连接中断':this.finishing||this.localOver?'保存成绩':this.paused?'已暂停':this.waiting?'等待同步':'挑战中';}
 get startLabel(){return this.finished?'再来一局':this.run?'继续挑战':'开始挑战';}
 get progressLabel(){if(!this.state){return '';}if(this.grid){return `${this.progress} / 2,000 步`;}if(this.game==='blocks'){return `${this.state.pieces} / 200 块`;}if(this.game==='merge'){return `${this.state.drops} / 100 次`;}const left=Math.max(0,Math.ceil((this.state.limit-this.progress)/60));return `${Math.floor(left/60)}:${String(left%60).padStart(2,'0')}`;}
 get controls(){if(this.game==='bird'){return [];}return this.game==='2048'||this.game==='snake'||this.game==='blocks'?['l','u','d','r']:['l','r'];}
 get controlsList(){return this.controls.map(k=>({key:k,label:{l:'←',r:'→',u:'↑',d:'↓'}[k]}));}
 @action async open(game){
  this.generation++;this.rankScope='all';this.game=game;this.run=null;this.playback=null;this.pending=null;this.error='';
  this.paused=true;this.finishing=false;this.waiting=false;this.localOver=false;this.saveRequested=false;this.ranking=null;
  this.effects=new Effects({reducedMotion:window.matchMedia('(prefers-reduced-motion: reduce)').matches});this.state=Core.create(game,Array(24).fill(3733));this.effects.observe(this.state);this.score=0;this.progress=0;this.loadRanking();
  if(game==='merge'){loadMergeSprites().then(images=>{if(!this.isDestroying){this.mergeSprites=images;this.effects.sprites=images;this.repaint=true;}});}
 }
 @action async back(){
  if(this.busy){return;}this.paused=true;this.playback?.release();await this.flush();
  if(!this.error&&!this.isDestroying){this.game=null;this.playback=null;this.generation++;}
 }
 @action async loadRanking(){const game=this.game;this.rankingError='';try{const r=await ajax('/rsc/arcade/ranking.json',{data:{game},ignoreUnsent:false,timeout:15000});if(this.game===game&&!this.isDestroying){this.ranking=r;if(!r.season){this.rankScope='all';}}}catch(e){if(!this.isDestroying){this.rankingError=extractError(e,"网络连接中断，请重试或读取已保存进度。");}}}
 @action async start(){
  if(this.busy||this.syncing||this.pending){return;}
  if(this.run?.status==='playing'&&!this.error){this.paused=false;this.canvas?.focus({preventScroll:true});return;}
  this.busy=true;this.error='';const generation=this.generation;
  try{
   const r=await ajax('/rsc/arcade/start.json',{ignoreUnsent:false,timeout:15000,type:'POST',contentType:'application/json',data:JSON.stringify({game:this.game,request_id:crypto.randomUUID()})});
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
    const r=await ajax(`/rsc/arcade/${p.run.id}/advance.json`,{ignoreUnsent:false,timeout:15000,type:'POST',contentType:'application/json',data:JSON.stringify(p.pending)});
    if(this.isDestroying||p!==this.playback){return;}
    p.acknowledge(r);this.updateView();
    if(r.status!=='playing'){this.paused=true;this.finishing=false;this.loadRanking();break;}
    // 2048 never receives future tiles. Queue swipes while awaiting the next
    // server tile, then immediately apply the next gesture to that board.
    if(this.grid&&!this.paused){p.advance();this.updateView();}
   }
  }catch(e){
   if(!this.isDestroying){this.error=extractError(e,"网络连接中断，请重试或读取已保存进度。");this.paused=true;p.release();}
  }finally{if(!this.isDestroying){this.syncing=false;this.syncPromise=null;}}
 }
 input(key){
  if(!this.playback||this.inputDisabled||this.error){return;}
  this.playback.input(key);if(this.grid){this.advanceFrame();}
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
   if(this.game==='merge'){this.input(aim(e));this.input('drop');}else if(this.game==='bird'){this.input('tap');}
  };
  const end=e=>{
   if(pointer&&(this.grid||this.game==='snake')){const dx=e.clientX-pointer.x,dy=e.clientY-pointer.y;if(Math.max(Math.abs(dx),Math.abs(dy))>15){this.input(Math.abs(dx)>Math.abs(dy)?dx>0?'r':'l':dy>0?'d':'u');}}
   pointer=null;
  };
  const cancel=()=>{pointer=null;this.playback?.release();};
  const move=e=>{if(this.game==='merge'){this.input(aim(e));}};
  const blur=()=>{this.pause();};const visibility=()=>{if(document.hidden){this.pause();}};
  canvas.addEventListener('keydown',key);window.addEventListener('keyup',up);canvas.addEventListener('pointerdown',down);canvas.addEventListener('pointerup',end);canvas.addEventListener('pointercancel',cancel);canvas.addEventListener('pointermove',move);window.addEventListener('blur',blur);document.addEventListener('visibilitychange',visibility);
  const loop=t=>{
   if(this.isDestroying){return;}const delta=Math.min(100,t-(this.last||t));this.last=t;
   if(!this.inputDisabled&&!this.error&&this.run?.status==='playing'){
    if(this.grid){this.advanceFrame();}else{
     this.accumulator+=delta;let count=0;
     while(this.accumulator>=1000/60&&count++<6){
      this.advanceFrame();this.accumulator-=1000/60;
      if(this.playback.blocked||this.state.over){this.accumulator=0;break;}
     }
    }
   }else{this.accumulator=0;}
   if(this.repaint||this.effects.active()){this.paint();this.repaint=false;}this.raf=requestAnimationFrame(loop);
  };this.raf=requestAnimationFrame(loop);
  return()=>{cancelAnimationFrame(this.raf);canvas.removeEventListener('keydown',key);window.removeEventListener('keyup',up);canvas.removeEventListener('pointerdown',down);canvas.removeEventListener('pointerup',end);canvas.removeEventListener('pointercancel',cancel);canvas.removeEventListener('pointermove',move);window.removeEventListener('blur',blur);document.removeEventListener('visibilitychange',visibility);this.canvas=null;this.playback?.release();};
 });
 <template>
  <section class="ra-app" aria-label="休闲挑战" {{this.boot}}>
   {{#unless this.game}}
    {{#if this.featured}}<button type="button" class="ra-season-banner" {{on "click" this.openSeason}}><div><span class="ra-season-eyebrow">第 {{this.featured.number}} 赛季 · {{if (eq this.featured.cadence "daily") "每日轮替" "每周轮替"}}</span><h3>{{this.featured.name}} <span aria-hidden="true">↗</span></h3><small>截止 {{this.featuredEnd}}</small></div><div class="ra-season-reward">{{#if this.featuredPrizes}}<small>前五名奖励 · RSC</small><strong>{{this.featuredPrizes}}</strong>{{else}}<small>本期仅排名，不发放 RSC</small>{{/if}}</div></button>{{else}}{{#if this.catalogError}}<p class="ra-rank-note">{{this.catalogError}} <button type="button" class="btn btn-flat" {{on "click" this.loadCatalog}}>重试</button></p>{{/if}}{{/if}}
    <div class="ra-catalog">{{#each this.games as |game|}}<button type="button" class="ra-card ra-card--{{game.color}}" {{on "click" (fn this.open game.id)}}><div class="ra-card-art" aria-hidden="true"><ArcadeArt @game={{game.id}} />{{#if (eq game.id this.featured.game)}}<span class="ra-featured-tag">本期挑战</span>{{/if}}<i></i><i></i><i></i></div><div class="ra-card-label"><div><h3>{{game.name}}</h3></div><span aria-hidden="true">↗</span></div></button>{{/each}}</div>
   {{else}}
    <header class="ra-heading"><button type="button" class="btn btn-flat" disabled={{or this.busy this.finishing}} {{on "click" this.back}}>← 返回挑战</button><h2>{{this.selected.name}}</h2><span class="ra-free">免费游玩</span></header>{{#if this.nonSeasonRun}}<p class="ra-rank-note">本局计入总排行；新开一局可参加当前赛季。</p>{{/if}}
    {{#if this.error}}<div class="rg-error" role="alert">{{this.error}}<button type="button" class="btn" disabled={{or this.busy this.syncing}} {{on "click" this.retry}}>重试并恢复进度</button><button type="button" class="btn btn-flat" disabled={{or this.busy this.syncing}} {{on "click" this.recover}}>读取已保存进度</button></div>{{/if}}
    <div class="ra-layout"><div class="ra-play">
     <div class="ra-scorebar"><div><small>本局得分</small><strong>{{this.score}}</strong></div><span role="status">{{if this.run this.status "准备就绪"}}</span><small>{{this.progressLabel}}</small></div>
     <canvas class="ra-canvas" tabindex="0" role="img" aria-label={{this.selected.name}} {{this.stage}}></canvas>
     <div class="ra-toolbar">{{#if (or this.paused this.finished)}}<button type="button" class="btn btn-primary ra-start" disabled={{this.navigationBusy}} {{on "click" this.start}}>{{this.startLabel}}</button>{{else}}<button type="button" class="btn" disabled={{this.busy}} {{on "click" this.pause}}>暂停</button>{{/if}}{{#if this.run}}{{#unless this.finished}}<button type="button" class="btn btn-flat" disabled={{or this.busy this.finishing}} {{on "click" this.finish}}>结束并保存</button>{{/unless}}{{/if}}</div>
     <div class="ra-controls">{{#each this.controlsList as |c|}}<button type="button" aria-label={{c.label}} disabled={{this.inputDisabled}} {{on "pointerdown" (fn this.press c.key)}} {{on "pointerup" (fn this.release c.key)}} {{on "pointercancel" (fn this.release c.key)}} {{on "lostpointercapture" (fn this.release c.key)}} {{on "click" (fn this.keyboardPress c.key)}}>{{c.label}}</button>{{/each}}{{#if (eq this.game "blocks")}}<button type="button" disabled={{this.inputDisabled}} {{on "pointerdown" this.dropPress}} {{on "click" this.dropKeyboard}}>落下</button>{{/if}}{{#if (eq this.game "merge")}}<button type="button" disabled={{this.inputDisabled}} {{on "pointerdown" this.dropPress}} {{on "click" this.dropKeyboard}}>投放</button>{{/if}}{{#if (eq this.game "bird")}}<button type="button" disabled={{this.inputDisabled}} {{on "pointerdown" this.dropPress}} {{on "click" this.dropKeyboard}}>起飞</button>{{/if}}</div>
     <details class="ra-rules"><summary>玩法与操作</summary><p>{{this.selected.rules}}</p><p>允许程序策略，正式成绩以服务器复核为准。后台同步成绩；网络长时间中断时暂停，恢复后继续；单局有效期最长 2 小时，跨期不计入新一期。</p></details>
    </div><aside class="ra-rank"><div class="ra-rank-heading"><div class="ra-rank-tabs"><button type="button" class={{if (eq this.rankScope "all") "is-active"}} {{on "click" (fn this.selectRank "all")}}>总排行</button>{{#if this.ranking.season}}<button type="button" class={{if (eq this.rankScope "season") "is-active"}} {{on "click" (fn this.selectRank "season")}}>赛季排行</button>{{/if}}</div><button type="button" class="btn btn-flat" {{on "click" this.loadRanking}}>刷新</button></div><p class="ra-rank-note">每人取最高分 · 同分并列</p>{{#if (eq this.rankScope "season")}}<p class="ra-rank-note">第 {{this.ranking.season.number}} 赛季 · 截止 {{this.endLabel}}</p>{{#if this.rankPrizes}}<p class="ra-prize-note">前五名：{{this.rankPrizes}} RSC</p><p class="ra-rank-note">同分平分所占名次奖金，结束后自动到账。</p>{{else}}<p class="ra-rank-note">本期仅排名，不发放 RSC</p>{{/if}}{{else}}<p class="ra-rank-note">历史最高分永久保留</p>{{/if}}{{#if this.rankingError}}<p role="alert">{{this.rankingError}}</p>{{/if}}<ol>{{#each this.rankRows as |row|}}<li><span class="ra-place">{{row.rank}}</span><ForumUser @user={{row.user}} /><strong>{{row.score}}</strong></li>{{else}}<li class="ra-empty">还没有成绩，来占个位置。</li>{{/each}}</ol></aside></div>
   {{/unless}}
  </section>
 </template>
}
