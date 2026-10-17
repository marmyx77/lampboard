// The relay's only shared memory: quota counters, the APNs token, usage.
//
// On Vercel this is the Runtime Cache (`@vercel/functions`): a key-value store
// per region and per environment, shared by every instance of the function,
// with a TTL on each entry. Nothing in it outlives an hour or two except the
// month's usage counter, and losing it all costs little: a quota window that
// starts again, one JWT minted early. That is why it needs no database and no
// Marketplace account (Q19: Hobby, non-commercial).
//
// It has no atomic increment, so two instances counting at the same moment can
// both write the same number: a quota can be overrun by the number of instances
// running at once. Each instance also counts in memory and the larger of the two
// counts wins, which keeps a single hot instance exact.

export class MemoryStore {
  constructor(clock = () => Date.now()) {
    this.kind = 'memory';
    this.clock = clock;
    this.entries = new Map();
  }

  async get(key) {
    const entry = this.entries.get(key);
    if (!entry) return undefined;
    if (entry.expires <= this.clock()) {
      this.entries.delete(key);
      return undefined;
    }
    return entry.value;
  }

  async set(key, value, ttlSeconds) {
    this.entries.set(key, { value, expires: this.clock() + ttlSeconds * 1000 });
  }
}

/** The Runtime Cache, or memory where there is none (outside Vercel, in tests). */
export async function defaultStore(env = process.env) {
  if (!env.VERCEL) return new MemoryStore();
  try {
    const { getCache } = await import('@vercel/functions');
    const cache = getCache({ namespace: 'lampboard-relay' });
    return {
      kind: 'runtime-cache',
      get: async (key) => {
        try {
          return await cache.get(key);
        } catch {
          return undefined;
        }
      },
      set: async (key, value, ttlSeconds) => {
        try {
          await cache.set(key, value, { ttl: ttlSeconds });
        } catch {
          // A lost write costs a counter or an early JWT, never a push.
        }
      },
    };
  } catch {
    return new MemoryStore();
  }
}

/** A counter that keeps the larger of its shared and its local value. */
export class Counter {
  constructor(store) {
    this.store = store;
    this.local = new Map();
  }

  async read(key) {
    const shared = Number(await this.store.get(key)) || 0;
    return Math.max(shared, this.local.get(key)?.value ?? 0);
  }

  /** Adds one and returns the new count. */
  async increment(key, ttlSeconds, now) {
    const next = (await this.read(key)) + 1;
    this.local.set(key, { value: next, expires: now + ttlSeconds * 1000 });
    // Forget local counts whose window has closed.
    if (this.local.size > 5000) {
      for (const [k, v] of this.local) if (v.expires <= now) this.local.delete(k);
    }
    await this.store.set(key, next, ttlSeconds);
    return next;
  }
}
