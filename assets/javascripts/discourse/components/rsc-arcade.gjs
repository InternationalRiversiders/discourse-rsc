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
import draw from "../lib/arcade-draw";
import { formatDateTime } from "../lib/campus-time";
const GAMES=[
 {id:'2048',name:'2048',caption:'滑动 · 合并 · 再大一点',mark:'2048',color:'sand',rules:'方向键或滑动合并相同数字，每次合并累加分数。最多 2,000 步，棋盘无法移动时结束。'},
 {id:'blocks',name:'方块堆叠',caption:'旋转落下，消去整行',mark:'▟',color:'lavender',rules:'左右移动，上键旋转，下键加速，空格落下。单次消除 1／2／3／4 行分别获得 100／300／500／800 分。最多 200 个方块或 5 分钟。'},
 {id:'snake',name:'贪吃蛇',caption:'沿着空隙，一口一口长大',mark:'⌁',color:'mint',rules:'方向键或滑动转向，吃到食物获得 100 分。不能直接掉头，撞墙、障碍或身体结束。最多 5 分钟。'},
 {id:'bird',name:'河畔飞鸟',caption:'轻点起飞，穿过下一道门',mark:'➤',color:'sky',rules:'轻点画面或空格拍动翅膀。每穿过一道障碍获得 1 分，碰撞即结束。最多 3 分钟。'},
 {id:'hex',name:'六角消除',caption:'转动六边，让同色相遇',mark:'⬡',color:'rose',rules:'左右旋转中心六边形，每条边堆叠的末尾三个同色块消除并获得 100 分。任一边达到 10 块时结束。最多 3 分钟。'},
 {id:'bricks',name:'打砖块',caption:'接住弹球，清空色块',mark:'▤',color:'peach',rules:'按住左右键移动挡板，手机按住屏幕下方方向按钮。每块砖 100 分，共 3 条生命，清空砖块或达到 5 分钟结束。'},
 {id:'merge',name:'合成大河畔',caption:'从小樱桃，到大西瓜',mark:'🍉',color:'green',rules:'移动指针选择落点，轻点投放；也可左右移动、空格投放。同级水果相碰合成，奖励随等级增加。越过虚线持续 3 秒则结束，最多 100 次投放或 5 分钟。'}
];
export default class extends Component {
 games=GAMES;
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
 state=null;frames=0;events=[];keys=[];held=new Set();canvas=null;raf=null;last=0;accumulator=0;generation=0;
 get selected(){return GAMES.find(g=>g.id===this.game);}
 get grid(){return this.game==='2048';}
 get continuous(){return this.game==='bricks';}
 get finished(){return this.run?.status==='finished';}
 get endLabel(){return this.ranking?.ends_at?formatDateTime(this.ranking.ends_at):'';}
 get status(){return this.finished?'成绩已保存':this.error?'连接中断':this.busy?'同步进度':this.paused?'已暂停':'挑战中';}
 get startLabel(){return this.finished?'再来一局':this.run?'继续挑战':'开始挑战';}
 get progressLabel(){if(!this.state){return '';}if(this.grid){return `${this.progress} / 2,000 步`;}if(this.game==='blocks'){return `${this.state.pieces} / 200 块`;}if(this.game==='merge'){return `${this.state.drops} / 100 次`;}const left=Math.max(0,Math.ceil((this.state.limit-this.progress)/60));return `${Math.floor(left/60)}:${String(left%60).padStart(2,'0')}`;}
 get controls(){if(this.game==='bird'){return [];}return this.game==='2048'||this.game==='snake'||this.game==='blocks'?['l','u','d','r']:['l','r'];}
 get controlsList(){return this.controls.map(k=>({key:k,label:{l:'←',r:'→',u:'↑',d:'↓'}[k]}));}
 @action async open(game){this.generation++;this.game=game;this.run=null;this.pending=null;this.error='';this.paused=true;this.ranking=null;this.state=Core.create(game,Array(24).fill(3733));this.score=0;this.progress=0;this.frames=0;this.events=[];this.keys=[];this.loadRanking();}
 @action back(){if(this.busy||this.pending){return;}this.paused=true;this.flush(false).then(()=>{if(!this.error&&!this.isDestroying){this.game=null;this.generation++;}});}
 @action async loadRanking(){const game=this.game;this.rankingError='';try{const r=await ajax('/rsc/arcade/ranking.json',{data:{game},ignoreUnsent:false,timeout:15000});if(this.game===game&&!this.isDestroying){this.ranking=r;}}catch(e){if(!this.isDestroying){this.rankingError=extractError(e,"网络连接中断，请重试或读取已保存进度。");}}}
 @action async start(){
  if(this.busy||this.pending){return;}
  this.busy=true;this.error='';const generation=this.generation;
  try{const r=await ajax('/rsc/arcade/start.json',{ignoreUnsent:false,timeout:15000,type:'POST',contentType:'application/json',data:JSON.stringify({game:this.game,request_id:crypto.randomUUID()})});if(this.isDestroying||generation!==this.generation){return;}this.accept(r);this.paused=false;this.canvas?.focus();}
  catch(e){if(!this.isDestroying){this.error=extractError(e,"网络连接中断，请重试或读取已保存进度。");}}
  finally{if(!this.isDestroying){this.busy=false;}}
 }
 accept(r){this.run=r;this.state=Core.advance(r.state,0,[]);this.score=this.state.score;this.progress=this.state.tick;this.frames=0;this.events=[];this.keys=[];if(r.status!=='playing'){this.paused=true;this.loadRanking();}this.paint();}
 paint(){if(this.canvas&&this.state){draw(this.canvas,this.state);}}
 @action async pause(){this.paused=true;this.held.clear();await this.flush(false);}
 @action async finish(){this.paused=true;this.held.clear();await this.flush(true);}
 @action recover(){if(this.busy){return;}this.pending=null;this.frames=0;this.events=[];this.keys=[];return this.start();}
 @action retry(){if(this.pending){return this.send();}return this.start();}
 async flush(finish){if(!this.run||this.run.status!=='playing'||this.busy||this.pending||(!this.frames&&!finish)){return;}
  this.pending={version:this.run.version,frames:this.frames,events:this.events.slice(),finish,request_id:crypto.randomUUID()};return this.send();
 }
 async send(){const pending=this.pending;if(!pending||this.busy){return;}this.busy=true;this.error='';
  try{const r=await ajax(`/rsc/arcade/${this.run.id}/advance.json`,{ignoreUnsent:false,timeout:15000,type:'POST',contentType:'application/json',data:JSON.stringify(pending)});if(this.isDestroying){return;}this.pending=null;this.accept(r);}
  catch(e){if(!this.isDestroying){this.error=extractError(e,"网络连接中断，请重试或读取已保存进度。");this.paused=true;}}
  finally{if(!this.isDestroying){this.busy=false;}}
 }
 input(key){if(!this.run||this.paused||this.busy||this.pending||this.finished){return;}if(this.keys.length<2){this.keys.push(key);}if(this.grid){this.advanceFrame();}}
 @action press(key,e){e?.preventDefault();this.input(key);if(this.continuous){this.held.add(key);}}
 @action release(){this.held.clear();}
 @action keyboardPress(key,e){if(e.detail===0){this.input(key);}}
 @action drop(){this.input(this.game==='bird'?'tap':'drop');}
 advanceFrame(){
  if(!this.state||this.state.over){return;}
  if(this.grid){const key=this.keys.shift();this.keys=[];if(!['l','r','u','d'].includes(key)){return;}this.events=[[0,key]];this.frames=1;this.state=Core.preview(this.state,key);this.score=this.state.score;this.paint();this.flush(false);return;}
  if(this.state.q.length<4){this.flush(false);return;}
  const keys=this.keys.splice(0,2);if(this.continuous){for(const k of this.held){if(keys.length<2&&!keys.includes(k)){keys.push(k);}}}
  const before=this.state.tick;Core.step(this.state,keys);
  if(this.state.tick!==before){keys.forEach(k=>this.events.push([this.frames,k]));this.frames++;this.score=this.state.score;if(this.state.tick%15===0||this.state.over){this.progress=this.state.tick;}}
  this.paint();if(this.grid||this.frames>=120||this.state.over||this.state.q.length<4){this.flush(false);}
 }
 stage=modifier((canvas)=>{
  this.canvas=canvas;this.paint();let pointer=null;
  const key=e=>{const k={ArrowLeft:'l',ArrowRight:'r',ArrowUp:'u',ArrowDown:'d',' ':'drop'}[e.key];if(!k){return;}e.preventDefault();if(!e.repeat||this.continuous){this.input(this.game==='bird'?'tap':k);}if(this.continuous){this.held.add(k);}};
  const up=()=>this.held.clear();
  const down=e=>{pointer={x:e.clientX,y:e.clientY};canvas.focus();if(this.game==='merge'){const r=canvas.getBoundingClientRect();this.keys=[`x:${Math.round(Math.max(0,Math.min(4000,(e.clientX-r.left)/r.width*4000)))}`];this.input('drop');}else if(this.game==='bird'){this.input('tap');}};
  const end=e=>{if(pointer&&(this.grid||this.game==='snake')){const dx=e.clientX-pointer.x,dy=e.clientY-pointer.y;if(Math.max(Math.abs(dx),Math.abs(dy))>15){this.input(Math.abs(dx)>Math.abs(dy)?dx>0?'r':'l':dy>0?'d':'u');}}pointer=null;};
  const move=e=>{if(this.game==='merge'&&this.run&&!this.paused&&!this.busy&&!this.keys.includes('drop')){const r=canvas.getBoundingClientRect();this.keys=[`x:${Math.round(Math.max(0,Math.min(4000,(e.clientX-r.left)/r.width*4000)))}`];}};
  const blur=()=>{this.pause();};const visibility=()=>{if(document.hidden){this.pause();}};
  canvas.addEventListener('keydown',key);canvas.addEventListener('keyup',up);canvas.addEventListener('pointerdown',down);canvas.addEventListener('pointerup',end);canvas.addEventListener('pointermove',move);window.addEventListener('blur',blur);document.addEventListener('visibilitychange',visibility);
  const loop=t=>{if(this.isDestroying){return;}const delta=Math.min(100,t-(this.last||t));this.last=t;
   if(!this.grid&&!this.paused&&!this.busy&&!this.pending&&this.run?.status==='playing'){this.accumulator+=delta;let count=0;while(this.accumulator>=1000/60&&count++<6&&!this.busy&&!this.pending){this.advanceFrame();this.accumulator-=1000/60;}}else{this.accumulator=0;}
   this.raf=requestAnimationFrame(loop);
  };this.raf=requestAnimationFrame(loop);
  return()=>{cancelAnimationFrame(this.raf);canvas.removeEventListener('keydown',key);canvas.removeEventListener('keyup',up);canvas.removeEventListener('pointerdown',down);canvas.removeEventListener('pointerup',end);canvas.removeEventListener('pointermove',move);window.removeEventListener('blur',blur);document.removeEventListener('visibilitychange',visibility);this.canvas=null;this.held.clear();};
 });
 <template>
  <section class="ra-app" aria-label="休闲挑战">
   {{#unless this.game}}
    <div class="ra-intro"><div><h2>玩一局，刷新自己</h2><p>免费挑战 · 每周排行</p></div><span class="ra-season-tag">本期仅排名，不发放 RSC</span></div>
    <div class="ra-catalog">{{#each this.games as |game|}}<button type="button" class="ra-card ra-card--{{game.color}}" {{on "click" (fn this.open game.id)}}><div class="ra-card-art" aria-hidden="true"><ArcadeArt @game={{game.id}} /><i></i><i></i><i></i></div><div class="ra-card-label"><div><h3>{{game.name}}</h3><p>{{game.caption}}</p></div><span aria-hidden="true">↗</span></div></button>{{/each}}</div>
   {{else}}
    <header class="ra-heading"><button type="button" class="btn btn-flat" disabled={{or this.busy this.pending}} {{on "click" this.back}}>← 返回挑战</button><h2>{{this.selected.name}}</h2><span class="ra-free">免费游玩</span></header>
    {{#if this.error}}<div class="rg-error" role="alert">{{this.error}}<button type="button" class="btn" disabled={{this.busy}} {{on "click" this.retry}}>重试并恢复进度</button><button type="button" class="btn btn-flat" disabled={{this.busy}} {{on "click" this.recover}}>读取已保存进度</button></div>{{/if}}
    <div class="ra-layout"><div class="ra-play">
     <div class="ra-scorebar"><div><small>本局得分</small><strong>{{this.score}}</strong></div><span role="status">{{if this.run this.status "准备就绪"}}</span><small>{{this.progressLabel}}</small></div>
     <canvas class="ra-canvas" tabindex="0" role="img" aria-label={{this.selected.name}} {{this.stage}}></canvas>
     <div class="ra-toolbar">{{#if (or this.paused this.finished)}}<button type="button" class="btn btn-primary ra-start" disabled={{or this.busy this.pending}} {{on "click" this.start}}>{{this.startLabel}}</button>{{else}}<button type="button" class="btn" disabled={{this.busy}} {{on "click" this.pause}}>暂停</button>{{/if}}{{#if this.run}}{{#unless this.finished}}<button type="button" class="btn btn-flat" disabled={{or this.busy this.pending}} {{on "click" this.finish}}>结束并保存</button>{{/unless}}{{/if}}</div>
     <div class="ra-controls">{{#each this.controlsList as |c|}}<button type="button" aria-label={{c.label}} disabled={{or this.paused this.busy}} {{on "pointerdown" (fn this.press c.key)}} {{on "pointerup" this.release}} {{on "pointerleave" this.release}} {{on "click" (fn this.keyboardPress c.key)}}>{{c.label}}</button>{{/each}}{{#if (eq this.game "blocks")}}<button type="button" disabled={{or this.paused this.busy}} {{on "click" this.drop}}>落下</button>{{/if}}{{#if (eq this.game "merge")}}<button type="button" disabled={{or this.paused this.busy}} {{on "click" this.drop}}>投放</button>{{/if}}{{#if (eq this.game "bird")}}<button type="button" disabled={{or this.paused this.busy}} {{on "click" this.drop}}>起飞</button>{{/if}}</div>
     <details class="ra-rules"><summary>玩法与操作</summary><p>{{this.selected.rules}}</p><p>允许程序策略，正式成绩以服务器复核为准。网络中断时暂停，恢复后继续；单局有效期最长 2 小时，跨期不计入新一期。</p></details>
    </div><aside class="ra-rank"><div class="ra-rank-heading"><h3>本周排行榜</h3><button type="button" class="btn btn-flat" {{on "click" this.loadRanking}}>刷新</button></div><p class="ra-rank-note">每人取最高分 · 同分并列</p>{{#if this.endLabel}}<p class="ra-rank-note">截止 {{this.endLabel}}</p>{{/if}}{{#if this.rankingError}}<p role="alert">{{this.rankingError}}</p>{{/if}}<ol>{{#each this.ranking.rows as |row|}}<li><span class="ra-place">{{row.rank}}</span><ForumUser @user={{row.user}} /><strong>{{row.score}}</strong></li>{{else}}<li class="ra-empty">还没有成绩，来占个位置。</li>{{/each}}</ol><p class="ra-rank-note">本期仅排名，不发放 RSC</p></aside></div>
   {{/unless}}
  </section>
 </template>
}
