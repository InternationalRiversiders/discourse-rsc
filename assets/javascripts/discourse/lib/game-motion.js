import { SCENE_GAMES } from "./game-3d-scenes";

// Presentation only: the server has already committed this round and its payout.
// A fresh round ID starts a fresh animation, even when the outcome repeats.
// `scene` resolves to a WebGL controller or null; CSS motion is the fallback.
export function animateGame(stage, round, done, { scene = null, onScene = null } = {}) {
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  if (!scene || !SCENE_GAMES.has(round.game)) return animateCss(stage, round, done, reduced);
  let cancelled = false, run = null, fallback = null, timer;
  const timeout = new Promise((resolve) => (timer = setTimeout(() => resolve(null), 2500)));
  Promise.race([scene, timeout]).then((ctl) => {
    clearTimeout(timer);
    if (cancelled) return;
    if (!ctl) {
      fallback = animateCss(stage, round, done, reduced);
      return;
    }
    onScene?.();
    run = ctl.play(round, { reduced });
    run.finished.then(() => { if (!cancelled) done(); });
  });
  return () => { cancelled = true; clearTimeout(timer); run?.cancel(); fallback?.(); };
}

function animateCss(stage, round, done, reduced) {
  const animations = [];
  let cancelled = false;
  const animate = (element, frames, duration, easing = 'cubic-bezier(.16,.65,.12,1)') => {
    // Reduced motion plays the same motion, shorter, rather than skipping to the result.
    if (element) animations.push(element.animate(frames, { duration: reduced ? duration * 0.55 : duration, easing, fill: 'both' }));
  };
  {
    if (round.game === 'roulette') {
      const disc = stage.querySelector('.rg-wheel-disc');
      const orbit = stage.querySelector('.rg-ball-orbit');
      const start = Number(stage.dataset.wheelAngle || 0);
      const target = Number(disc.dataset.angle);
      const end = start + 1440 + ((target - start % 360 + 360) % 360);
      stage.dataset.wheelAngle = String(end);
      animate(disc, [{ transform: `rotate(${start}deg)` }, { transform: `rotate(${end}deg)` }], 3800);
      animate(orbit, [{ transform: 'rotate(0deg)' }, { transform: 'rotate(-2160deg)' }], 3800);
      animate(stage.querySelector('.rg-wheel-ball'), [
        { top: '1%', offset: 0 }, { top: '1%', offset: .65 },
        { top: '9%', offset: .88 }, { top: '7%', offset: .94 }, { top: '9%', offset: 1 },
      ], 3800, 'linear');
    } else if (round.game === 'slots') {
      stage.querySelectorAll('.rg-reel-strip').forEach((strip, i) => {
        const height = strip.parentElement.getBoundingClientRect().height;
        const end = -(strip.children.length - 1) * height;
        animate(strip, [{ transform: 'translateY(0)' }, { transform: `translateY(${end}px)` }], 1300 + i * 400);
      });
    } else if (round.game === 'dice') {
      stage.querySelectorAll('.rg-die-cube').forEach((cube, i) => {
        const x = Number(cube.dataset.x), y = Number(cube.dataset.y);
        animate(cube, [
          { transform: 'translateY(0) rotateX(0deg) rotateY(0deg)', offset: 0 },
          { transform: `translateY(-38px) rotateX(${360+x}deg) rotateY(${360+y}deg)`, offset: .45 },
          { transform: `translateY(0) rotateX(${720+x}deg) rotateY(${720+y}deg)`, offset: .82 },
          { transform: `translateY(-7px) rotateX(${720+x}deg) rotateY(${720+y}deg)`, offset: .91 },
          { transform: `translateY(0) rotateX(${720+x}deg) rotateY(${720+y}deg)`, offset: 1 },
        ], 1300 + i * 200, 'ease-out');
      });
    } else if (round.game === 'coin') {
      const end = 2160 + (round.state.landed === 'tails' ? 180 : 0);
      animate(stage.querySelector('.rg-coin-flipper'), [
        { transform: 'translateY(0) rotateY(0deg)', offset: 0 },
        { transform: 'translateY(-65px) rotateY(990deg) rotateZ(-12deg)', offset: .4 },
        { transform: `translateY(0) rotateY(${end}deg) rotateZ(0deg)`, offset: .86 },
        { transform: `translateY(-8px) rotateY(${end}deg)`, offset: .93 },
        { transform: `translateY(0) rotateY(${end}deg)`, offset: 1 },
      ], 2000, 'ease-in-out');
      animate(stage.querySelector('.rg-object-shadow'), [{ transform: 'scale(1)', opacity: .6 }, { transform: 'scale(.5)', opacity: .2, offset: .4 }, { transform: 'scale(1)', opacity: .6 }], 2000);
    }
  }
  Promise.all(animations.map(a => a.finished)).then(() => {
    if (!cancelled) done();
  }).catch(() => {}); // Route changes cancel presentation, never the committed round.
  return () => { cancelled = true; animations.forEach(a => a.cancel()); };
}
