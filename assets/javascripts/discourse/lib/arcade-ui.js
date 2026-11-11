import drawCover from "./arcade-cover";
import Core from "./arcade-core";
const escape=(value)=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const button=(action,label,cls='btn btn-flat',arg='')=>`<button type="button" class="${cls}" data-action="${action}" data-arg="${escape(arg)}">${label}</button>`;
const icon=(kind)=>kind==='info'?'<svg viewBox="0 0 24 24" aria-hidden="true"><circle cx="12" cy="12" r="9" fill="none" stroke="currentColor" stroke-width="2"/><path d="M12 11v6M12 7v1" fill="none" stroke="currentColor" stroke-width="2.5"/></svg>':'<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M20 10a8 8 0 0 0-14-4L3 9m0-6v6h6M4 14a8 8 0 0 0 14 4l3-3m0 6v-6h-6" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>';
function userHTML(user){
 if(!user?.username){return '<span class="rsc-user-label">—</span>';}
 const name=escape(user.username),href='/u/'+encodeURIComponent(user.username);
 let avatar='';try{const url=new URL(String(user.avatar_template||'').replace('{size}','48'),location.origin);if(['https:','http:'].includes(url.protocol)&&!url.username&&!url.password){avatar=`<img src="${escape(url.href)}" width="24" height="24" alt="" loading="lazy">`;}}catch{}
 return `<a class="rsc-forum-user" href="${escape(href)}" data-user-card="${name}" data-action="profile" data-arg="${name}">${avatar}<span>${name}</span></a>`;
}
function setText(root,selector,value){const el=root.querySelector(selector);if(el&&el.textContent!==String(value??'')){el.textContent=value??'';}}
function disabled(root,selector,value){root.querySelectorAll(selector).forEach(el=>{el.disabled=!!value;});}
function hidden(root,selector,value){const el=root.querySelector(selector);if(el){el.hidden=!!value;}}
function lobby(app){
 const root=app.root,featured=app.featured;
 const banner=root.querySelector('.ra-banner-slot');
 const prizes=featured?.prizes||[];
 const html=featured?`<div class="ra-season-banner rh-banner"><span class="rh-banner-title"><small>第 ${escape(featured.number)} 赛季</small><strong>${escape(featured.name)}</strong><span>${featured.cadence==='daily'?'每日轮替':'每周轮替'} · 截止 ${escape(app.featuredEnd)}</span></span><span class="rh-banner-metric"><small>前 ${prizes.length} 名 · 奖励总额</small><strong>${prizes.reduce((a,n)=>a+Number(n),0)} <small>RSC</small></strong></span><span class="ra-banner-actions">${button('seasonInfo','奖励详情','ra-banner-detail')}${button('season','去挑战 →','rh-banner-cta')}</span></div>`:`<div class="rh-banner-placeholder">${escape(app.args.catalogError||'')}${app.args.catalogError?button('catalog','重试'):''}</div>`;
 if(app.bannerHTML!==html){banner.innerHTML=html;app.bannerHTML=html;}
 const info=root.querySelector('.ra-season-details');info.hidden=!app.seasonInfo||!featured;
 const infoButton=root.querySelector('[data-action=seasonInfo]');infoButton?.setAttribute('aria-expanded',String(app.seasonInfo));
 if(app.seasonInfo&&featured){const details=`<div class="ra-prize-grid">${prizes.map((p,i)=>`<div><span>第 ${i+1} 名</span><strong>${escape(p)} RSC</strong></div>`).join('')}</div><p>同分平分所占名次奖金；赛季结束后自动到账。</p>`;if(info.innerHTML!==details)info.innerHTML=details;}
 root.querySelectorAll('.ra-featured-tag').forEach(el=>{el.hidden=el.dataset.game!==featured?.game;});
}
export function renderArcade(app){
 const root=app.root;
 if(app.layout!==app.game){
  app.stageCleanup?.();app.coverCleanups?.forEach(fn=>fn());app.coverCleanups=[];app.layout=app.game;app.rankHTML=null;app.bannerHTML=null;app.helpHTML=null;
  if(!app.game){
   root.innerHTML=`<div class="ra-banner-slot"></div><div class="ra-season-details" hidden></div><div class="ra-catalog">${app.games.map(g=>`<button type="button" class="ra-card ra-card--${g.color}" data-action="open" data-arg="${g.id}"><div class="ra-card-art" aria-hidden="true"><canvas class="ra-art ra-cover" data-game="${g.id}"></canvas><span class="ra-featured-tag" data-game="${g.id}" hidden>本期挑战</span></div><div class="ra-card-label"><h3>${g.name}</h3><span aria-hidden="true">↗</span></div></button>`).join('')}</div>`;
   root.querySelectorAll('canvas.ra-cover').forEach(c=>app.coverCleanups.push(drawCover(c,c.dataset.game)));
  }else{
   const controls=app.hasControls?`<div class="ra-controls" data-game="${app.game}">${[...app.controlsList,...(app.game==='blocks'?[{key:'tap',label:'↶'},{key:'x:0',label:'暂存'},{key:'drop',label:'落下'}]:[])].map(c=>`<button type="button" data-key="${c.key}" aria-label="${c.label}">${c.label}</button>`).join('')}</div>`:'';
   const sudoku=app.game==='sudoku'?`<div class="ra-sudoku-board"><div class="ra-sudoku-grid" role="grid" aria-label="数独棋盘">${Array.from({length:9},(_,r)=>`<div role="row">${Array.from({length:9},(_,c)=>`<button type="button" role="gridcell" data-cell="${r*9+c}" data-action="cell" data-arg="${r*9+c}"></button>`).join('')}</div>`).join('')}</div><div class="ra-sudoku-complete" role="status" hidden><span aria-hidden="true">✓</span><strong></strong></div></div><div class="ra-sudoku-tools">${button('note','✎ 笔记','btn')}${button('erase','擦除','btn')}${button('undo','撤销','btn')}</div><div class="ra-sudoku-digits">${Array.from({length:9},(_,i)=>button('digit',String(i+1),'',String(i+1))).join('')}</div>`:'';
   const heading=app.fixedGame?'':`<header class="ra-heading">${button('back','← 返回挑战')}<h2>${escape(app.selected.name)}</h2></header>`;
   root.innerHTML=`${heading}<p class="ra-rank-note ra-nonseason" hidden>本局计入总排行；新开一局可参加当前赛季。</p>
    <div class="rg-error" role="alert" hidden><span class="ra-error-text"></span>${button('retry','重试并恢复进度','btn')}${button('recover','读取已保存进度')}</div>
    <div class="ra-layout"><div class="ra-play" data-game="${app.game}"><div class="ra-scorebar"><div><small>本局得分</small><strong>0</strong></div><span role="status">准备就绪</span><small class="ra-progress"></small></div>
    ${app.game==='blocks'?'<div class="ra-block-previews" aria-label="方块预览"></div>':''}<div class="ra-stage" data-game="${app.game}"><canvas class="ra-canvas" data-game="${app.game}" tabindex="0" role="img" aria-label="${escape(app.selected.name)}"></canvas>${controls}${sudoku}</div>${app.grid?button('touchKeys','方向键','btn ra-touch-toggle'):''}
    <div class="ra-toolbar">${button('start','开始挑战','btn btn-primary ra-start')}${button('pause','暂停并保存','btn')}${button('finish','结束并保存')}</div>
    <details class="ra-rules"><summary>玩法与操作</summary>${app.game==='hex'?'<div class="ra-hex-demo" aria-label="三个相邻同色块连成一组即可消除"><span>↶</span><i></i><i></i><i></i><span>→ 消除</span></div>':''}<p>${escape(app.rulesText)}</p><p>允许程序策略，正式成绩以服务器复核为准。后台同步成绩；网络长时间中断时暂停，恢复后继续；存档每次操作后保留 30 天，可暂停后回来继续；赛季结束自动结算已同步的进度，跨期不计入新赛季。</p></details>
    </div><aside class="ra-rank"><div class="ra-rank-heading"><div class="ra-rank-tabs">${button('rank','赛季排行','','season')}${button('rank','总排行','','all')}</div><div class="ra-rank-tools"><button type="button" class="rg-icon-button" data-action="info" aria-label="排行说明" title="排行说明" aria-expanded="false">${icon('info')}</button><button type="button" class="rg-icon-button" data-action="ranking" aria-label="刷新排行" title="刷新排行">${icon('refresh')}</button></div></div><div class="rg-rules ra-rank-help" hidden></div><p class="ra-ranking-error" role="alert" hidden></p><ol></ol></aside></div>`;
   app.stageCleanup=app.attachStage(root.querySelector('.ra-canvas'));
  }
 }
 if(!app.game){lobby(app);return;}
 if(app.game==='sudoku')renderSudoku(app);
 if(app.game==='2048'){
  root.querySelector('.ra-controls').hidden=!app.touchKeys;
  root.querySelector('[data-action=touchKeys]').setAttribute('aria-expanded',String(app.touchKeys));
 }
 if(app.game==='blocks'){
  const previews=[['暂存 · C',app.state?.holdShape],['下一块',app.state?.nextShape]];
  const html=previews.map(([label,shape])=>`<div><small>${label}</small><span class="ra-piece-preview" aria-label="${shape===undefined?'空':label}">${Array.from({length:8},(_,i)=>`<i class="${Core.shapes[shape]?.some(([x,y])=>x===i%4&&y===Math.floor(i/4))?'is-filled':''}" data-shape="${shape??''}"></i>`).join('')}</span></div>`).join('');
  const el=root.querySelector('.ra-block-previews');if(el.innerHTML!==html)el.innerHTML=html;
 }

 setText(root,'.ra-scorebar div small',app.game==='sudoku'?'已通关':'本局得分');
 hidden(root,'.ra-nonseason',!app.nonSeasonRun);hidden(root,'.rg-error',!app.error);setText(root,'.ra-error-text',app.error);
 disabled(root,'[data-action=back]',app.busy||app.finishing);disabled(root,'[data-action=retry],[data-action=recover]',app.busy||app.syncing);
 setText(root,'.ra-scorebar strong',app.score);setText(root,'.ra-scorebar [role=status]',app.run?app.status:'准备就绪');setText(root,'.ra-progress',app.progressLabel);
 disabled(root,'[data-key]',app.inputDisabled);
 hidden(root,'[data-action=start]',!app.paused&&!app.finished);setText(root,'[data-action=start]',app.startLabel);disabled(root,'[data-action=start]',app.navigationBusy);
 hidden(root,'[data-action=pause]',app.paused||app.finished);disabled(root,'[data-action=pause]',app.busy);
 hidden(root,'[data-action=finish]',!app.run||app.finished);disabled(root,'[data-action=finish]',app.busy||app.finishing);
 hidden(root,'[data-arg=season]',!app.ranking?.season);root.querySelectorAll('.ra-rank-tabs button').forEach(b=>{b.classList.toggle('is-active',b.dataset.arg===app.rankScope);});
 root.querySelector('[data-action=info]').setAttribute('aria-expanded',String(app.rankInfo));hidden(root,'.ra-rank-help',!app.rankInfo);
 const help=`<p>${app.game==='sudoku'?'每人取最高通关数，同关数并列。':'每人取最高分，同分并列。'}</p>${app.rankScope==='season'?`<p>第 ${escape(app.ranking?.season?.number)} 赛季 · 截止 ${escape(app.endLabel)}</p>${app.rankPrizes?`<p>第 1–${escape(app.ranking.season.prizes.length)} 名依次：${escape(app.rankPrizes)} RSC</p><p>同分平分所占名次奖金，结束后自动到账。</p>`:'<p>本期仅排名，不发放 RSC</p>'}`:'<p>历史最高分永久保留。</p>'}`;
 if(app.helpHTML!==help){root.querySelector('.ra-rank-help').innerHTML=help;app.helpHTML=help;}
 hidden(root,'.ra-ranking-error',!app.rankingError);setText(root,'.ra-ranking-error',app.rankingError);
 const rows=app.rankRows,html=rows?.length?rows.map(r=>`<li><span class="ra-place">${escape(r.rank)}</span>${userHTML(r.user)}<strong>${escape(r.score)}${app.game==='sudoku'?' 关':''}</strong></li>`).join(''):'<li class="ra-empty">还没有成绩，来占个位置。</li>';
 if(app.rankHTML!==html){root.querySelector('.ra-rank ol').innerHTML=html;app.rankHTML=html;}
}

function renderSudoku(app){
 const s=app.sudokuCompletion||app.state;if(!s?.board)return;
 const completed=!!app.sudokuCompletion;
 app.root.querySelector('.ra-sudoku-board').classList.toggle('is-complete',completed);
 hidden(app.root,'.ra-sudoku-complete',!completed);
 setText(app.root,'.ra-sudoku-complete strong',completed?`第 ${s.level} 关完成`:'');const selected=app.sudokuCell,value=s.board[selected];
 app.root.querySelectorAll('[data-cell]').forEach(el=>{
  const i=Number(el.dataset.cell),r=Math.floor(i/9),c=i%9,peer=r===Math.floor(selected/9)||c===selected%9||(Math.floor(r/3)===Math.floor(selected/27)&&Math.floor(c/3)===Math.floor(selected%9/3));
  const conflict=!!s.board[i]&&s.board.some((v,j)=>j!==i&&v===s.board[i]&&(Math.floor(j/9)===r||j%9===c||(Math.floor(j/27)===Math.floor(r/3)&&Math.floor(j%9/3)===Math.floor(c/3))));
  el.classList.toggle('is-selected',i===selected);el.classList.toggle('is-peer',peer);el.classList.toggle('is-same',!!value&&s.board[i]===value);el.classList.toggle('is-given',!!s.givens[i]);el.classList.toggle('is-conflict',conflict);
  el.style.setProperty("--cell-wave",`${(r+c)*35}ms`);
  el.tabIndex=i===selected?0:-1;el.setAttribute('aria-selected',String(i===selected));el.setAttribute('aria-readonly',String(!!s.givens[i]));
  el.setAttribute('aria-label',`第 ${r+1} 行第 ${c+1} 列，${s.board[i]||'空格'}${s.givens[i]?'，题目数字':''}${conflict?'，重复冲突':''}`);
  const html=s.board[i]?String(s.board[i]):`<span class="ra-sudoku-notes">${Array.from({length:9},(_,n)=>`<span>${s.notes[i]&(1<<(n+1))?n+1:''}</span>`).join('')}</span>`;
  if(el.innerHTML!==html)el.innerHTML=html;
 });
 const note=app.root.querySelector('[data-action=note]');note.classList.toggle('is-active',app.sudokuNote);note.setAttribute('aria-pressed',String(app.sudokuNote));
 disabled(app.root,'.ra-sudoku-digits button,[data-action=note],[data-action=erase],[data-action=undo]',app.inputDisabled||s.awaiting);
 disabled(app.root,'[data-action=undo]',app.inputDisabled||s.awaiting||!s.history?.length);
}
