import Core from '../../assets/javascripts/discourse/lib/arcade-core.js';
const state=Core.create('merge',Array(24).fill(18377));
state.balls=Array.from({length:65},(_,i)=>({id:i,x:500+i%8*420,y:2000+Math.floor(i/8)*300,level:i%3,vx:0,vy:0}));
const start=performance.now();const result=Core.advance(state,120,[]);console.log('120 frames / 65 fruits:',Math.round(performance.now()-start),'ms; remaining',result.balls.length);
