// Reading a long topic must not spend the forum's request budget one post at a
// time. Keep one request in flight and batch posts across rendering frames.
export default class TipRequests {
  constructor({ request, now = Date.now, setTimer = (fn, delay) => setTimeout(fn, delay), clearTimer = (timer) => clearTimeout(timer) }) {
    Object.assign(this, { request, now, setTimer, clearTimer });
    this.pending = new Map();
    this.inFlight = new Map();
    this.cache = new Map();
    this.nextRequestAt = 0;
    this.pausedUntil = 0;
  }

  get(post, refresh = false) {
    const key = `${post.topic_id}:${post.id}`;
    const cached = this.cache.get(key);
    if (!refresh && cached && this.now() - cached.at < 120000) {
      return Promise.resolve(cached.value);
    }
    if (this.stopped || this.now() < this.pausedUntil) {
      return cached ? Promise.resolve(cached.value) : Promise.reject(this.lastError || new Error("Tip summaries unavailable"));
    }
    const flight = this.inFlight.get(key);
    if (flight) {
      // A successful tip must be fetched after any older read has finished.
      return refresh ? flight.then(() => this.get(post, true)) : flight;
    }
    if (this.pending.has(key)) {
      return this.pending.get(key).promise;
    }
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    this.pending.set(key, { key, topic: post.topic_id, id: post.id, promise, resolve, reject });
    this.schedule();
    return promise;
  }

  schedule() {
    if (this.stopped || this.timer || this.running || !this.pending.size) { return; }
    this.timer = this.setTimer(() => {
      this.timer = null;
      this.flush();
    }, Math.max(250, this.nextRequestAt - this.now()));
  }

  async flush() {
    if (this.stopped || this.running || !this.pending.size) { return; }
    const topic = this.pending.values().next().value.topic;
    const batch = [...this.pending.values()].filter((item) => item.topic === topic).slice(0, 100);
    for (const item of batch) {
      this.pending.delete(item.key);
      this.inFlight.set(item.key, item.promise);
    }
    this.running = true;
    this.nextRequestAt = this.now() + 1000;
    try {
      const data = await this.request(topic, batch.map((item) => item.id));
      for (const item of batch) {
        const value = data.posts[item.id] || { total: "0", count: 0, tips: [] };
        if (!this.stopped) {
          this.cache.delete(item.key);
          this.cache.set(item.key, { value, at: this.now() });
        }
        item.resolve(value);
      }
      while (this.cache.size > 2000) { this.cache.delete(this.cache.keys().next().value); }
    } catch (error) {
      this.lastError = error;
      // Do not automatically retry a 429. Respect Retry-After and let a later
      // page render/manual refresh request summaries once the cooldown ends.
      let delay = 5000;
      if (error.status === 429) {
        const retry = error.getResponseHeader?.("Retry-After");
        const seconds = retry && /^\d+(\.\d+)?$/.test(retry) ? Number(retry) : NaN;
        const date = retry ? Date.parse(retry) : NaN;
        delay = Number.isFinite(seconds) ? seconds * 1000 : Number.isFinite(date) ? date - this.now() : 60000;
        delay = Math.max(1000, delay);
      }
      this.pausedUntil = this.now() + delay;
      for (const item of [...batch, ...this.pending.values()]) { item.reject(error); }
      this.pending.clear();
    } finally {
      for (const item of batch) { this.inFlight.delete(item.key); }
      this.running = false;
      this.schedule();
    }
  }

  destroy() {
    this.stopped = true;
    this.clearTimer(this.timer);
    this.timer = null;
    for (const item of this.pending.values()) { item.reject(new Error("Tip summaries destroyed")); }
    this.pending.clear();
    this.cache.clear();
  }
}
