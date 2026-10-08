// ingest/db-memory.js
// Local-development stand-in for Postgres, used only when DATABASE_URL is
// unset outside production. Nothing survives a restart, and the one accepted
// agent token is SENTINEL_DEV_TOKEN. Production refuses to boot without a database.

function createMemoryStore({ devToken }) {
  const seen = new Map();      // server_id -> Set of event ids (bounded)
  const lastSeq = new Map();
  const findingKeys = new Set();
  const SEEN_CAP = 50_000;

  return {
    mode: 'memory',
    describe: () => 'in-memory (volatile, lost on restart; local development only)',
    sslWarning: null,
    init: async () => ({ applied: [], total: 0 }),
    ping: async () => true,
    loadRecent: async () => ({ events: [], findings: [], alerts: [], rules: null }),

    // Memory mode has no servers table: the dev token is accepted, and the
    // batch's own server_id is trusted (see server.js).
    authenticate: async (token) => (token === devToken
      ? { ok: true, server: { id: null, name: 'dev', dev: true } }
      : { ok: false, reason: 'unknown' }),

    recordBatch: async (server, batch) => {
      const sid = batch.server_id;
      if (!seen.has(sid)) seen.set(sid, new Set());
      const ids = seen.get(sid);
      const now = Date.now();
      const inserted = [];
      for (const e of batch.events) {
        if (ids.has(e.id)) continue;
        ids.add(e.id);
        inserted.push({ ...e, server_id: sid, received_at: now });
      }
      if (ids.size > SEEN_CAP) {
        const keep = [...ids].slice(-SEEN_CAP / 2);
        seen.set(sid, new Set(keep));
      }
      lastSeq.set(sid, batch.seq);
      return { received: inserted.length, deduped: batch.events.length - inserted.length, inserted };
    },

    saveFinding: async (serverId, f, { refresh = false } = {}) => {
      const k = `${serverId}|${f.key}`;
      if (findingKeys.has(k)) return { inserted: false };
      findingKeys.add(k);
      return { inserted: true, refresh };
    },
    saveAlert: async () => {},
    saveRules: async () => {},
    purge: async () => ({ events: 0 }),
    close: async () => {},
  };
}

module.exports = { createMemoryStore };
