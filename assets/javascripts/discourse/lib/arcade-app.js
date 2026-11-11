import Core from "./arcade-core";
import Playback from "./arcade-playback";
import draw from "./arcade-draw";
import Effects from "./arcade-effects";
import { loadMergeSprites } from "./arcade-sprites";
import { formatDateTime } from "./campus-time";
import { renderArcade } from "./arcade-ui";

const GAMES=[
 {id:'2048',name:'2048',mark:'2048',color:'sand'},
 {id:'blocks',name:'方块堆叠',mark:'▟',color:'lavender'},
 {id:'snake',name:'贪吃蛇',mark:'⌁',color:'mint'},
 {id:'bird',name:'河畔飞鸟',mark:'➤',color:'sky'},
 {id:'hex',name:'六角消除',mark:'⬡',color:'rose'},
 {id:'bricks',name:'打砖块',mark:'▤',color:'peach'},
 {id:'merge',name:'合成大河畔',mark:'🍉',color:'green'},
 {id:'sudoku',name:'数独',mark:'9',color:'lavender'}
];
const ENDLESS_RULES={
 sudoku:'每行、每列及每个九宫格填入 1–9，不能重复。完整填对即进入下一关，按通关数排名，同关数并列。数字键填数，方向键选格，N 切换笔记，Delete 或 Backspace 擦除，Ctrl/Cmd+Z 撤销。笔记只记录候选数，不提供答案。',
 '2048':'方向键或滑动合并相同数字，每次合并累加分数。没有步数和倒计时限制，棋盘无法移动时结束。',
 blocks:'左右移动，上键旋转，下键加速，空格落下。消除 1／2／3／4 行获得 100／300／500／800 分；消行越多下落越快，堆到顶部结束。',
 snake:'方向键或滑动转向，吃到食物获得 100 分。不能直接掉头，撞墙、障碍或身体结束，填满可用格子通关。',
 bird:'轻点画面或空格拍动翅膀。每穿过一道障碍获得 1 分，速度和难度随进度逐步增加，碰撞结束。',
 hex:'左右旋转中心六边形，三个及以上相邻同色块消除，可跨相邻边连接。每三个约 100 分，连续消除有倍数加分；任一边堆到 10 块结束。',
 bricks:'拖动画面或按住键盘左右键移动挡板，每消除一块砖获得 100 分。清屏进入下一关，后续有更耐打的砖块、不同布局和更快球速，3 条生命耗尽结束。',
 merge:'按住拖动选择落点，松手投放；也可左右移动、空格投放。同级图案相碰合成，得分随等级增加。可贴墙投放，越过虚线持续 3 秒结束。'
};
export default class ArcadeApp {
 games=GAMES;
 rankScope='all';
 rankInfo=false;
 seasonInfo=false;
 sudokuCompletion=null;
 sudokuCompletedLevel=null;
 clearSudokuCompletion(){clearTimeout(this.sudokuCompletionTimer);this.sudokuCompletion=null;this.scheduleRender();}
 observeSudokuCompletion(state){
  if(this.game!=='sudoku'||!state.awaiting||this.sudokuCompletedLevel===state.level)return;
  this.sudokuCompletedLevel=state.level;
  this.sudokuCompletion=structuredClone(state);
  clearTimeout(this.sudokuCompletionTimer);
  this.sudokuCompletionTimer=setTimeout(()=>{this.sudokuCompletion=null;this.scheduleRender();},1800);
 }
 sudokuCell=0;
 sudokuNote=false;
 sudokuSelect(i){this.sudokuCell=Number(i);this.scheduleRender();}
 sudokuWrite(n){this.input(`${this.sudokuNote?'n':'v'}:${this.sudokuCell}:${n}`);}
 sudokuKey(e){
  if(this.game!=='sudoku'||e.isComposing||e.altKey||e.target.closest('input,textarea,select'))return;
  const k=e.key.toLowerCase(),dirs={arrowleft:-1,a:-1,arrowright:1,d:1,arrowup:-9,w:-9,arrowdown:9,s:9};
  if((e.ctrlKey||e.metaKey)&&k==='z'){e.preventDefault();this.input('undo');return;}
  if(e.ctrlKey||e.metaKey)return;
  if(k in dirs){e.preventDefault();this.sudokuSelect(Math.max(0,Math.min(80,this.sudokuCell+dirs[k])));this.root.querySelector(`[data-cell="${this.sudokuCell}"]`)?.focus({preventScroll:true});}
  else if(/^[1-9]$/.test(k)){e.preventDefault();this.sudokuWrite(k);}
  else if(['backspace','delete','0'].includes(k)){e.preventDefault();this.input(`v:${this.sudokuCell}:0`);}
  else if(k==='n'){e.preventDefault();this.sudokuNote=!this.sudokuNote;this.scheduleRender();}
 }
 toggleRankInfo(){this.rankInfo=!this.rankInfo;}
 rankChosen=false;
 game=null;
 run=null;
 busy=false;
 paused=true;
 error='';
 ranking=null;
 rankingError='';
 score=0;
 progress=0;
 pending=null;
 syncing=false;
 finishing=false;
 waiting=false;
 localOver=false;
 effects=new Effects();repaint=true;mergeSprites=null;
 playback=null;state=null;canvas=null;raf=null;last=0;accumulator=0;generation=0;
 syncPromise=null;saveRequested=false;lastInputAt=0;
 get fixedGame(){return this.args.embedded&&this.args.game;}
 get selected(){return GAMES.find(g=>g.id===this.game);}
 get rulesVersion(){return Core.version;}
 get rulesText(){
  const keyboard=['2048','blocks','snake','sudoku'].includes(this.game)?'方向键也可使用 WASD。':['hex','bricks','merge'].includes(this.game)?'左右键也可使用 A／D。':'';
  return `${ENDLESS_RULES[this.game]} ${keyboard}Esc 暂停并保存。`;
 }
 get grid(){return this.game==='2048';}
 get turnBased(){return this.grid||this.game==='sudoku';}
 get finished(){return this.run?.status==='finished';}
 get inputDisabled(){return this.paused||this.busy||this.finishing||this.finished||this.localOver||!!this.sudokuCompletion;}
 get navigationBusy(){return this.busy||this.syncing||!!this.pending;}
 get endLabel(){return this.ranking?.season?.ends_at?formatDateTime(this.ranking.season.ends_at):'';}
 get featured(){return this.args.catalog?.current;}
 get featuredEnd(){return this.featured?formatDateTime(this.featured.ends_at):'';}
 get featuredPrizes(){return this.featured?.prizes?.slice(0,5).join(' / ') || '';}
 get rankPrizes(){return this.ranking?.season?.prizes?.join(' / ') || '';}
 get rankRows(){return this.rankScope==='season'?this.ranking?.season?.rows:this.ranking?.rows;}
 get nonSeasonRun(){return this.run&&this.ranking?.season&&this.run.season_id!==this.ranking.season.id;}
 selectRank(scope){this.rankScope=scope;this.rankChosen=true;}
 openSeason(){if(this.featured){this.open(this.featured.game);this.rankScope='season';}}
 get status(){return this.finished?'成绩已保存':this.error?'连接中断':this.sudokuCompletion?'本关完成':this.finishing||this.localOver?'保存成绩':this.paused?'已暂停':this.waiting?'等待同步':'挑战中';}
 get startLabel(){return this.finished?'再来一局':this.run?'继续挑战':'开始挑战';}
 get progressLabel(){if(!this.state){return '';}if(this.grid){return `${this.progress} 步`;}if(this.game==='sudoku'){return `第 ${this.sudokuCompletion?.level||this.state.level||1} 关`;}if(this.game==='blocks'){return `${this.state.lines} 行`;}if(this.game==='merge'){return `${this.state.drops} 次投放`;}if(this.game==='bricks'){return `第 ${this.state.wave||1} 关`;}if(this.game==='bird'){return `${this.score} 道障碍`;}return '';}
 get controls(){return ['blocks','snake'].includes(this.game)?['u','l','d','r']:this.game==='hex'?['l','r']:[];}
 get hasControls(){return ['blocks','snake','hex'].includes(this.game);}
 focusPlay(){if(this.game==='sudoku'){this.root.querySelector(`[data-cell="${this.sudokuCell}"]`)?.focus({preventScroll:true});return;}this.canvas?.focus({preventScroll:true});if(window.innerWidth<=767){this.canvas?.closest('.ra-play')?.scrollIntoView({block:'start',behavior:'instant'});}}
 get controlsList(){return this.controls.map(k=>({key:k,label:{l:'←',r:'→',u:'↑',d:'↓'}[k]}));}
 async open(game){
  if(this.fixedGame&&game!==this.args.game){return;}
  this.clearSudokuCompletion();this.sudokuCompletedLevel=null;
  this.generation++;this.rankInfo=false;this.rankChosen=false;this.rankScope=this.featured?.game===game?'season':'all';this.game=game;this.run=null;this.playback=null;this.pending=null;this.error='';
  this.paused=true;this.finishing=false;this.waiting=false;this.localOver=false;this.saveRequested=false;this.ranking=null;
  this.effects=new Effects({reducedMotion:window.matchMedia('(prefers-reduced-motion: reduce)').matches});this.state=Core.create(game,Array(24).fill(3733),this.rulesVersion);this.effects.observe(this.state);this.score=0;this.progress=0;this.loadRanking();
  if(game==='merge'){loadMergeSprites().then(images=>{if(!this.isDestroying){this.mergeSprites=images;this.effects.sprites=images;this.repaint=true;}});}
 }
 async back(){
  if(this.fixedGame){return;}
  if(this.busy||this.finishing){return;}this.paused=true;this.playback?.release();await this.flush();
  if(!this.error&&!this.isDestroying){this.clearSudokuCompletion();this.startKey=null;this.game=null;this.playback=null;this.generation++;}
 }
 async loadRanking(){const game=this.game;this.rankingError='';try{const r=await this.request('ranking',{game});if(this.game===game&&!this.isDestroying){this.ranking=r;this.args.updateSeason?.(r.featured);if(!this.rankChosen){this.rankScope=r.season?'season':'all';}else if(!r.season){this.rankScope='all';}}}catch(e){if(!this.isDestroying){this.rankingError=this.errorText(e);}}}
 start(){
  if(this.startPromise){return this.startPromise;}
  this.startPromise=this.startRun().finally(()=>{this.startPromise=null;});return this.startPromise;
 }
 async startRun(){
  if(this.busy||this.syncing||this.pending){return;}
  if(this.run?.status==='playing'&&!this.error){this.hostPaused=false;this.paused=false;this.focusPlay();return;}
  this.hostPaused=false;this.busy=true;this.error='';const generation=this.generation;
  try{
   const r=await this.request('start',{game:this.game,request_id:this.startKey ||= crypto.randomUUID(),rules_version:this.rulesVersion,scope:this.rankScope});
   if(this.isDestroying||generation!==this.generation){return;}
   this.effects=new Effects({reducedMotion:window.matchMedia('(prefers-reduced-motion: reduce)').matches});this.effects.sprites=this.mergeSprites;this.clearSudokuCompletion();this.sudokuCompletedLevel=null;this.playback=new Playback(r);this.finishing=false;this.saveRequested=false;this.updateView();
   this.startKey=null;this.paused=this.hostPaused||r.status!=='playing';this.focusPlay();
  }catch(e){if(!this.isDestroying){this.error=this.errorText(e);}}
  finally{if(!this.isDestroying){this.busy=false;}}
 }
 updateView(){
  const p=this.playback;if(!p){return;}
  this.observeSudokuCompletion(p.state);
  this.run=p.run;this.state=p.state;this.pending=p.pending;this.score=p.state.score;
  if(this.turnBased||p.state.tick%15===0||p.state.over){this.progress=p.state.tick;}
  this.waiting=p.blocked&&!p.state.over;this.localOver=p.state.over;this.effects.observe(p.state,p.visualMove);this.repaint=true;if(this.game==='sudoku')this.scheduleRender();
 }
 paint(){if(this.canvas&&this.state){draw(this.canvas,this.state,this.effects);}}
 async pause(){this.hostPaused=true;this.paused=true;this.playback?.release();await this.startPromise;this.paused=true;this.playback?.release();await this.flush();}
 async finish(){this.clearSudokuCompletion();this.paused=true;this.playback?.release();if(this.playback){this.playback.keys=[];}await this.flush(true);}
 recover(){
  if(this.busy||this.syncing){return;}
  this.pending=null;this.playback=null;this.run=null;this.startKey=null;this.finishing=false;this.error='';return this.start();
 }
 async retry(){
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
    const r=await this.request('advance',{id:p.run.id,...p.pending,rules_version:this.rulesVersion});
    if(this.isDestroying||p!==this.playback){return;}
    p.acknowledge(r);this.updateView();
    if(r.status!=='playing'){this.paused=true;this.finishing=false;this.loadRanking();break;}
    // Consume queued gestures after a refill, without waiting between moves.
    if(this.turnBased&&!this.paused){p.advance();this.updateView();}
   }
  }catch(e){
   if(!this.isDestroying){this.error=this.errorText(e);this.paused=true;p.release();}
  }finally{if(!this.isDestroying){this.syncing=false;this.syncPromise=null;}}
 }
 input(key){
  if(!this.playback||this.inputDisabled||this.error){return;}
  this.lastInputAt=performance.now();this.playback.input(key);if(this.turnBased){this.advanceFrame();}
 }
 press(key,e){
  e?.preventDefault();if(this.inputDisabled){return;}
  e?.currentTarget?.setPointerCapture?.(e.pointerId);
  this.canvas?.focus({preventScroll:true});this.input(key);this.playback?.hold(key);
 }
 release(key){this.playback?.release(key);}
 keyboardPress(key,e){if(e.detail===0){this.input(key);}}
 dropPress(e){this.press('drop',e);}
 dropKeyboard(e){if(e.detail===0){this.input('drop');}}
 advanceFrame(){
  const p=this.playback;if(!p){return;}
  if(p.advance()){this.updateView();}
  if(p.needsSync){this.flush();}
 }
 attachStage(canvas){
  this.canvas=canvas;this.paint();let pointer=null;
  const keyMap={ArrowLeft:'l',ArrowRight:'r',ArrowUp:'u',ArrowDown:'d',a:'l',d:'r',w:'u',s:'d',' ':'drop'};
  const mapped=e=>keyMap[e.key]||keyMap[e.key?.toLowerCase()];
  const escape=e=>{
   if(e.key!=='Escape'||e.repeat||e.isComposing||e.ctrlKey||e.metaKey||e.altKey||e.target.closest?.('input,textarea,select,[contenteditable="true"]')){return;}
   if(this.run?.status==='playing'&&!this.paused&&!this.finishing){e.preventDefault();e.stopPropagation();this.pause();}
  };
  const key=e=>{
   if(e.isComposing||e.ctrlKey||e.metaKey||e.altKey){return;}
   if(this.game==='sudoku')return;const k=mapped(e);if(!k){return;}e.preventDefault();
   if(!e.repeat&&!this.inputDisabled){this.input(this.game==='bird'?'tap':k);this.playback?.hold(k);}
  };
  const up=e=>{const k=mapped(e);if(k){this.playback?.release(k);}};
  const aim=e=>{const r=canvas.getBoundingClientRect();return `x:${Math.round(Math.max(0,Math.min(4000,(e.clientX-r.left)/r.width*4000)))}`;};
  const down=e=>{
   if(pointer||this.inputDisabled){return;}e.preventDefault();canvas.setPointerCapture(e.pointerId);pointer={id:e.pointerId,x:e.clientX,y:e.clientY,swiped:false};canvas.focus({preventScroll:true});
   if(this.game==='bricks'&&this.rulesVersion>=2){this.input(aim(e));}else if(this.game==='merge'){this.input(aim(e));}
  };
  const playArea=canvas.closest('.ra-play');
  const flap=e=>{if(this.game!=='bird'||this.inputDisabled||e.target.closest('button,a,input,summary,details')){return;}e.preventDefault();canvas.focus({preventScroll:true});this.input('tap');};
  playArea.addEventListener('pointerdown',flap);
  const swipe=e=>{
   if(pointer&&pointer.id===e.pointerId&&!pointer.swiped&&(this.grid||this.game==='snake')){const dx=e.clientX-pointer.x,dy=e.clientY-pointer.y;if(Math.max(Math.abs(dx),Math.abs(dy))>15){pointer.swiped=true;this.input(Math.abs(dx)>Math.abs(dy)?dx>0?'r':'l':dy>0?'d':'u');}}
  };
  const end=e=>{
   if(!pointer||pointer.id!==e.pointerId){return;}swipe(e);
   if(this.game==='merge'&&!this.inputDisabled){this.input(aim(e));this.input('drop');}
   pointer=null;
  };
  const cancel=()=>{pointer=null;this.playback?.release();};
  const move=e=>{swipe(e);if((!pointer||pointer.id===e.pointerId)&&(this.game==='merge'||(pointer&&this.game==='bricks'&&this.rulesVersion>=2))){this.input(aim(e));}};
  const blur=()=>{cancel();this.pause();};const visibility=()=>{if(document.hidden){cancel();this.pause();}};
  this.root.addEventListener('keydown',escape);canvas.addEventListener('keydown',key);window.addEventListener('keyup',up);canvas.addEventListener('pointerdown',down);canvas.addEventListener('pointerup',end);canvas.addEventListener('pointercancel',cancel);canvas.addEventListener('pointermove',move);window.addEventListener('blur',blur);document.addEventListener('visibilitychange',visibility);
  const loop=t=>{
   if(this.isDestroying){return;}const delta=Math.min(100,t-(this.last||t));this.last=t;
   if(!this.inputDisabled&&!this.error&&this.run?.status==='playing'){
    if(this.turnBased){this.advanceFrame();if(this.playback.frames&&!this.syncing&&t-this.lastInputAt>=(this.game==='sudoku'?1500:250)){this.flush();}}else{
     this.accumulator+=delta;let count=0;
     while(this.accumulator>=1000/60&&count++<6){
      this.advanceFrame();this.accumulator-=1000/60;
      if(this.playback.blocked||this.state.over){this.accumulator=0;break;}
     }
    }
   }else{this.accumulator=0;}
   if(this.repaint||this.effects.active()){this.paint();this.repaint=false;}this.raf=requestAnimationFrame(loop);
  };this.raf=requestAnimationFrame(loop);
  return()=>{this.root.removeEventListener('keydown',escape);playArea.removeEventListener('pointerdown',flap);cancelAnimationFrame(this.raf);canvas.removeEventListener('keydown',key);window.removeEventListener('keyup',up);canvas.removeEventListener('pointerdown',down);canvas.removeEventListener('pointerup',end);canvas.removeEventListener('pointercancel',cancel);canvas.removeEventListener('pointermove',move);window.removeEventListener('blur',blur);document.removeEventListener('visibilitychange',visibility);this.canvas=null;this.playback?.release();};
 }

 constructor(root,options){
  this.root=root;this.args=options;this.request=options.request;this.startKey=null;this.hostPaused=false;
  this.errorText=options.errorText||((e)=>e?.message||'网络连接中断，请重试或读取已保存进度。');
  for(const name of ['rankScope','rankInfo','game','run','busy','paused','error','ranking','rankingError','score','progress','pending','syncing','finishing','waiting','localOver']){
   let value=this[name];Object.defineProperty(this,name,{get:()=>value,set:(next)=>{if(value!==next){value=next;this.scheduleRender();}}});
  }
  this.click=(e)=>{const b=e.target.closest('[data-action]');if(!b||!root.contains(b)||b.disabled){return;}
   const action=b.dataset.action,arg=b.dataset.arg;
   if(action==='profile'){if(options.onProfile){e.preventDefault();options.onProfile(arg);}return;}
   const actions={seasonInfo:()=>{this.seasonInfo=!this.seasonInfo;this.scheduleRender();},cell:()=>this.sudokuSelect(arg),digit:()=>this.sudokuWrite(arg),note:()=>{this.sudokuNote=!this.sudokuNote;this.scheduleRender();},erase:()=>this.input(`v:${this.sudokuCell}:0`),undo:()=>this.input('undo'),open:()=>this.open(arg),back:()=>this.back(),start:()=>this.start(),pause:()=>this.pause(),finish:()=>this.finish(),retry:()=>this.retry(),recover:()=>this.recover(),rank:()=>this.selectRank(arg),info:()=>this.toggleRankInfo(),ranking:()=>this.loadRanking(),season:()=>this.openSeason(),catalog:()=>options.reloadCatalog?.()};
   if(actions[action]){Promise.resolve(actions[action]()).catch(error=>{this.error=this.errorText(error);});}
  };
  this.pointerDown=(e)=>{const b=e.target.closest('[data-key]');if(b&&root.contains(b)){this.press(b.dataset.key,{preventDefault:()=>e.preventDefault(),currentTarget:b,pointerId:e.pointerId});}};
  this.pointerUp=(e)=>{const b=e.target.closest('[data-key]');if(b){this.release(b.dataset.key);}};
  this.keyClick=(e)=>{const b=e.target.closest('[data-key]');if(b&&e.detail===0){this.input(b.dataset.key);}};
  this.sudokuKeyboard=e=>this.sudokuKey(e);root.addEventListener('keydown',this.sudokuKeyboard);root.addEventListener('click',this.click);root.addEventListener('click',this.keyClick);root.addEventListener('pointerdown',this.pointerDown);
  for(const event of ['pointerup','pointercancel','lostpointercapture']){root.addEventListener(event,this.pointerUp);}
  this.render();if(options.game&&GAMES.some(g=>g.id===options.game)){this.open(options.game);}
 }
 scheduleRender(){if(this.renderQueued||this.isDestroying||this.closing){return;}this.renderQueued=true;queueMicrotask(()=>{this.renderQueued=false;if(!this.isDestroying&&!this.closing){this.render();}});}
 render(){renderArcade(this);}
 update(options){Object.assign(this.args,options);this.scheduleRender();}
 async saveForHost(){
  await this.pause();
  if(this.error&&this.playback){this.error='';await this.flush();}
  this.paused=true;this.playback?.release();
  const saved=!this.busy&&!this.syncing&&!this.pending&&!this.playback?.frames&&!this.error;
  return {saved,run_id:this.run?.id||null,version:this.run?.version??null,status:this.run?.status||null,...(!saved?{error:this.error||'进度尚未同步，请重试保存。'}:{})};
 }
 async resumeForHost(){
  // Never discard an unacknowledged request or invent a new request ID.
  if(this.pending||this.playback?.frames){const saved=await this.saveForHost();if(!saved.saved){return saved;}}
  if(this.game&&this.run?.status==='playing'){
   this.run=null;this.playback=null;
   const started=this.start();this.hostPaused=true;await started;
  }
  this.paused=true;return {saved:!this.error,run_id:this.run?.id||null,version:this.run?.version??null,...(this.error?{error:this.error}:{})};
 }
 destroy(){
  this.clearSudokuCompletion();this.closing=true;this.stageCleanup?.();this.coverCleanups?.forEach(fn=>fn());
  this.root.removeEventListener('keydown',this.sudokuKeyboard);this.root.removeEventListener('click',this.click);this.root.removeEventListener('click',this.keyClick);this.root.removeEventListener('pointerdown',this.pointerDown);
  for(const event of ['pointerup','pointercancel','lostpointercapture']){this.root.removeEventListener(event,this.pointerUp);}
  return this.pause().finally(()=>{this.isDestroying=true;this.generation++;});
 }
}
export { GAMES };
