import assert from 'node:assert/strict';
import fs from 'node:fs';
import Core from '../../assets/javascripts/discourse/lib/arcade-core.js';
const url=s=>'data:text/javascript;base64,'+Buffer.from(s).toString('base64');
const coreUrl=url(fs.readFileSync(new URL('../../assets/javascripts/discourse/lib/arcade-core.js',import.meta.url),'utf8'));
const {default:Playback}=await import(url(fs.readFileSync(new URL('../../assets/javascripts/discourse/lib/arcade-playback.js',import.meta.url),'utf8').replace('"./arcade-core"',JSON.stringify(coreUrl))));
function solve(b){b=b.slice();function visit(){const i=b.indexOf(0);if(i<0)return true;for(let n=1;n<=9;n++){const r=Math.floor(i/9),c=i%9;if(b.some((v,j)=>v===n&&(Math.floor(j/9)===r||j%9===c||(Math.floor(j/27)===Math.floor(r/3)&&Math.floor(j%9/3)===Math.floor(c/3)))))continue;b[i]=n;if(visit())return true;}b[i]=0;return false;}assert(visit());return b;}
let worst=0;
for(let seed=1;seed<=30;seed++)for(const level of [1,3,4,7,8,30]){
 const start=performance.now(),p=Core.sudokuPuzzle(seed*79831,level);worst=Math.max(worst,performance.now()-start);
 assert.equal(p.length,81);assert.equal(Core.sudokuSolutions(p),1);assert(Core.sudokuValid(solve(p)));
 assert.equal(Core.sudokuGrade(p),level<=3?1:level<=7?2:3);
 assert.deepEqual(p,Core.sudokuPuzzle(seed*79831,level));
}
const puzzle=Core.sudokuPuzzle(123,1),answer=solve(puzzle);
let state=Core.sudokuLoad(Core.create('sudoku',[]),puzzle),i=puzzle.indexOf(0),given=puzzle.findIndex(Boolean);
state=Core.advance(state,1,[[0,`v:${given}:0`]]);assert.equal(state.board[given],puzzle[given]);
state=Core.advance(state,1,[[0,`n:${i}:2`]]);assert.equal(state.notes[i],4);
state=Core.advance(state,1,[[0,`v:${i}:3`]]);assert.equal(state.notes[i],0);
state=Core.advance(state,1,[[0,'undo']]);assert.equal(state.board[i],0);assert.equal(state.notes[i],4);
state=Core.advance(state,1,[[0,`v:${i}:0`]]);assert.equal(state.notes[i],0);
assert.equal(state.score,0);assert.throws(()=>Core.advance(state,1,[[0,'v:1:99']]));
let r={id:1,game:'sudoku',status:'playing',version:0,state};const p=new Playback(r);
const play=key=>{p.input(key);p.advance();};
play(`n:${i}:5`);const request=p.checkpoint('same-request');play(`v:${i}:${answer[i]}`);
const expected=structuredClone(p.state);r={...r,version:1,state:Core.advance(r.state,request.frames,request.events)};p.acknowledge(r);assert.deepEqual(p.state,expected,'ack replays local tail during latency');
for(let j=0;j<81;j++)if(!puzzle[j])play(`v:${j}:${answer[j]}`);
assert.equal(p.state.score,1);assert(p.state.awaiting);assert(p.blocked);assert(p.needsSync);
play(`v:${i}:0`);assert.equal(p.state.board[i],answer[i]);
const req=p.checkpoint('complete');const authoritative=Core.advance(r.state,req.frames,req.events);assert.equal(authoritative.score,1);
const next=Core.sudokuLoad(authoritative,Core.sudokuPuzzle(456,2));p.acknowledge({...r,version:2,state:next});assert.equal(p.state.level,2);assert(!p.blocked);assert.equal(p.state.score,1);assert(p.state.notes.every(n=>n===0));assert.equal(p.keys.length,0);
assert(!Core.sudokuValid(Array(81).fill(1)));
console.log('PASS 180 unique reproducible graded puzzles, immutable givens, notes/undo, replay, weak-network tail and next-level gating; worst generation ms',Math.round(worst));
