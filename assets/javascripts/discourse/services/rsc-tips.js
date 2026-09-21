import Service from "@ember/service";
import { ajax } from "discourse/lib/ajax";
// Coalesce visible posts into one same-origin request. Cache is scoped to the
// current forum session; no JWT exchange and no request to the legacy backend.
export default class extends Service {
  pending = new Map();
  cache = new Map();
  timer;
  get(post, refresh = false) {
    const key = `${post.topic_id}:${post.id}`;
    const cached = this.cache.get(key);
    if (!refresh && cached && Date.now() - cached.at < 30000) {
      return Promise.resolve(cached.value);
    }
    return new Promise((resolve, reject) => {
      const topic = this.pending.get(post.topic_id) || new Map();
      const waiters = topic.get(post.id) || [];
      waiters.push({ resolve, reject });
      topic.set(post.id, waiters);
      this.pending.set(post.topic_id, topic);
      if (!this.timer) { this.timer = setTimeout(() => this.flush(), 15); }
    });
  }
  async flush() {
    this.timer = null;
    const pending = this.pending;
    this.pending = new Map();
    for (const [topicId, posts] of pending) {
      const ids = [...posts.keys()];
      for (let start = 0; start < ids.length; start += 100) {
        const batch = ids.slice(start, start + 100);
        try {
          const data = await ajax(`/rsc/topics/${topicId}/tips.json`, { data: { post_ids: batch.join(",") } });
          for (const id of batch) {
            const value = data.posts[id] || { total: "0", count: 0, tips: [] };
            this.cache.set(`${topicId}:${id}`, { value, at: Date.now() });
            for (const waiter of posts.get(id)) { waiter.resolve(value); }
          }
        } catch (error) {
          for (const id of batch) { for (const waiter of posts.get(id)) { waiter.reject(error); } }
        }
      }
    }
  }
}
