import Core from "./arcade-core";

// One immutable request in flight, plus a bounded, locally simulated tail.
// The server remains authoritative. Refills are appended to the same random
// prefix, so replaying the tail on an acknowledgement never changes its draws.
export default class ArcadePlayback {
  constructor(run) {
    this.run = run;
    this.state = Core.advance(run.state, 0, []);
    this.frames = 0;
    this.events = [];
    this.keys = [];
    this.held = new Map();
    this.pending = null;
  }

  get grid() { return this.run.game === "2048"; }
  get privateGrid() { return this.grid && !Array.isArray(this.state.q); }
  get blocked() {
    return this.privateGrid ? !!this.pending || this.frames > 0 : this.frames >= (this.grid ? 16 : 180) || this.state.q.length < 4;
  }
  get needsSync() {
    return this.frames > 0 && (this.privateGrid || this.frames >= (this.grid ? 4 : 120) || this.state.over || this.state.q.length < 8);
  }

  input(key) {
    if (this.state.over || this.run.status !== "playing") { return; }
    if ((this.grid || this.run.game === "snake") && !["l", "r", "u", "d"].includes(key)) { return; }
    if (key.startsWith("x:")) {
      this.keys = this.keys.filter(k => !k.startsWith("x:"));
    }
    // A pending fruit drop is enough; don't build up unintended future drops.
    if (this.run.game === "merge" && key === "drop" && this.keys.includes(key)) { return; }
    if (this.keys.length < 64) { this.keys.push(key); }
  }

  hold(key) {
    const game = this.run.game;
    if ((["blocks", "bricks", "hex", "merge"].includes(game) && ["l", "r"].includes(key)) ||
        (game === "blocks" && key === "d")) {
      if (!this.held.has(key)) { this.held.set(key, 0); }
    }
  }
  release(key) { key ? this.held.delete(key) : this.held.clear(); }

  advance() {
    if (this.blocked || this.state.over || this.run.status !== "playing") { return false; }
    if (this.grid) {
      const key = this.keys.shift();
      if (!key) { return false; }
      this.visualMove = {direction:key,board:this.state.board.slice(),tick:this.state.tick+1};
      if(this.privateGrid){this.state=Core.preview(this.state,key);}else{Core.step(this.state,[key]);}
      this.events.push([this.frames,key]);
      this.frames++;
      return true;
    }
    const keys = [];
    // Consume at most two distinct inputs per frame. Preserve the rest instead
    // of dropping rapid taps or a snake's second turn before it moves a cell.
    this.keys = this.keys.filter(key => {
      if (keys.length >= 2 || keys.includes(key)) { return true; }
      if (this.run.game === "snake" && (this.state.turned || keys.length)) { return true; }
      if (this.run.game === "merge" && key === "drop" && this.state.cooldown > 0) { return true; }
      keys.push(key);
      return false;
    });
    for (const [key, age] of this.held) {
      const continuous = this.run.game === "bricks" || (this.run.game === "blocks" && key === "d");
      if ((continuous || (age >= 12 && (age - 12) % 4 === 0)) && keys.length < 2 && !keys.includes(key)) {
        keys.push(key);
      }
      this.held.set(key, age + 1);
    }
    Core.step(this.state, keys);
    keys.forEach(key => this.events.push([this.frames, key]));
    this.frames++;
    return true;
  }

  checkpoint(requestId, finish = false) {
    if (this.pending) { return this.pending; }
    if (!this.frames && !finish) { return null; }
    this.pending = {
      version: this.run.version, request_id: requestId,
      frames: this.frames, events: this.events, finish,
    };
    this.frames = 0;
    this.events = [];
    return this.pending;
  }

  acknowledge(run) {
    if (!this.pending || run.id !== this.run.id || run.version !== this.pending.version + 1) {
      throw new Error("进度版本发生变化，请读取已保存进度。");
    }
    const state = Core.advance(run.state, run.status === "playing" ? this.frames : 0, run.status === "playing" ? this.events : []);
    this.run = run;
    this.state = state;
    this.pending = null;
    if (run.status !== "playing") { this.frames=0;this.events=[];this.keys = []; this.release(); }
  }
}
