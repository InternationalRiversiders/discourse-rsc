// Lobby covers: stills rendered offline from these exact poses by
// script/render-game-covers.cjs, plus the hover attract loop. Bump COVER_VERSION
// with every re-render (production caches /plugins for a year).
export const COVER_VERSION = "v1";
export const COVER_STATES = {
  slots: { id: 101, version: 1, state: { symbols: ["seven", "seven", "seven"] } },
  roulette: { id: 102, version: 1, state: { number: 0 } },
  scratch: null,
  blackjack: { id: 104, version: 1, stake: "25", state: { player: [0, 11], dealer: [25, null] } },
  coin: { id: 105, version: 1, state: { landed: "heads" } },
  dice: { id: 106, version: 1, state: { dice: [6, 5, 3] } },
};
const SCRATCH_SPOTS = Array.from({ length: 10 }, (_, i) =>
  i === 1 ? { won: true, payout: "50", multiplier: 50 } : i === 4 ? { won: true, payout: "5", multiplier: 5 } : { won: false, payout: "0" });
export const COVER_TICKET = { purchased: true, serial: 2026, price: "10", unit: "1", spots: SCRATCH_SPOTS };

// Covers freeze a moment of action where it reads better than the resting state.
const COVER_POSES = {
  coin: [{ id: 7, version: 1, state: { landed: "tails" } }, { id: 8, version: 1, state: { landed: "heads" } }, 0.74],
  dice: [{ id: 3, version: 1, state: { dice: [1, 2, 3] } }, { id: 6, version: 1, state: { dice: [6, 5, 3] } }, 0.55],
};

export function applyCover(ctl, game) {
  if (game === "scratch") {
    ctl.setTicket(COVER_TICKET, { opened: [0, 1, 2, 4] });
  } else if (COVER_POSES[game] && ctl.pose) {
    const [from, to, t] = COVER_POSES[game];
    ctl.show(from);
    ctl.pose(to, t);
    ctl.resize();
  } else {
    ctl.show(COVER_STATES[game]);
  }
}

const DEMO = {
  slots: (n) => ({ symbols: [["seven", "seven", "seven"], ["cherry", "cherry", "bell"], ["diamond", "diamond", "diamond"], ["lemon", "clover", "seven"]][n % 4] }),
  roulette: (n) => ({ number: [17, 0, 32, 8][n % 4] }),
  coin: (n) => ({ landed: n % 2 ? "heads" : "tails" }),
  dice: (n) => ({ dice: [[6, 5, 3], [1, 1, 4], [2, 6, 6], [5, 3, 1]][n % 4] }),
};

// Attract loop for a hovered card; returns a stop function.
export function attract(ctl, game) {
  let n = 0, timer = 0, stopped = false;
  const next = async () => {
    if (stopped) return;
    n++;
    if (DEMO[game]) {
      await ctl.play({ id: 900 + n, version: 1, net: n % 2 ? "1" : "0", status: "settled", state: DEMO[game](n) }).finished;
    } else if (game === "blackjack") {
      await ctl.play({ id: 900 + n, version: 1, stake: "25", status: "playing", state: { player: [n * 7 % 52, (n * 11 + 3) % 52], dealer: [(n * 5 + 9) % 52, null] } }).finished;
      if (stopped) return;
      await ctl.play({ id: 900 + n, version: 2, stake: "25", status: "settled", net: "25", state: { player: [n * 7 % 52, (n * 11 + 3) % 52], dealer: [(n * 5 + 9) % 52, (n * 13 + 1) % 52] } }).finished;
    } else if (game === "scratch") {
      ctl.setTicket({ ...COVER_TICKET, serial: 3000 + n }, { animate: true });
      await new Promise((r) => setTimeout(r, 900));
      if (stopped) return;
      await ctl.revealAll();
      if (!stopped) ctl.celebrate();
    }
    if (!stopped) timer = setTimeout(next, 1400);
  };
  timer = setTimeout(next, 250);
  return () => { stopped = true; clearTimeout(timer); };
}
