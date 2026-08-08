// Sentinel fake agent — synthetic batch generator (wire protocol v1)
// Save as: C:\dev\sentinel\agent\fake-agent.js
// Run:     node agent/fake-agent.js   (in a SECOND terminal, with server.js running)
//
// This file is the reference implementation for the real Lua agent later —
// keep it honest to the spec.

const { ulid } = require('ulid');

const CONFIG = {
  endpoint: 'http://localhost:3000/v1/ingest',
  token: 'dev_token_change_me',
  serverId: 'srv_FAKE_LEGACY_RP',
  flushIntervalMs: 5000,
};

const bootedAt = Date.now();
let seq = 0;

// ---- Synthetic event generators ------------------------------------------
const PLAYERS = ['Kaiden_R', 'Dev_Marcus', 'Mod_Sarah', 'Player_4471', 'Jess_T', 'BigMike'];
const RESOURCES = ['esx_inventory', 'es_extended', 'oxmysql', 'bsd_banking', 'bsd_machines'];
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];
const rand = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;

function makeEvent() {
  const roll = Math.random();
  const base = { id: `evt_${ulid()}`, t: Date.now(), src: 'server' };

  if (roll < 0.30) {
    return { ...base, type: 'player.join', data: {
      player: pick(PLAYERS),
      license: `license:${ulid().slice(0, 12).toLowerCase()}`,
    }};
  }
  if (roll < 0.50) {
    return { ...base, type: 'player.drop', data: {
      player: pick(PLAYERS),
      reason: pick(['Exiting', 'Timed out', 'Kicked by admin', 'Banned: mod menu (txAdmin)']),
      session_s: rand(120, 14400),
    }};
  }
  if (roll < 0.70) {
    return { ...base, type: 'econ.txn', src: 'bsd_banking', data: {
      player: pick(PLAYERS),
      direction: pick(['in', 'out']),
      amount: rand(50, 5000),
      source: 'bsd_banking:deposit',
      balance_after: rand(1000, 900000),
    }};
  }
  if (roll < 0.85) {
    return { ...base, type: 'perf.resmon', src: pick(RESOURCES), data: {
      resource: pick(RESOURCES),
      avg_ms: +(Math.random() * 2).toFixed(2),
      peak_ms: +(Math.random() * 40).toFixed(1),
      samples: 30,
    }};
  }
  return { ...base, type: 'server.hitch', data: {
    ms: rand(150, 900),
    players: rand(20, 64),
    active_resources: rand(120, 145),
  }};
}

 function dupeBurstEvents() {
  const player = 'Player_4471';
  const base = 2300 + rand(0, 300);
  const count = rand(150, 250);
  console.log(`[fake-agent] >>> DUPE BURST: ${player}, ${count} txns of ~$${base}`);
  return Array.from({ length: count }, (_, i) => ({
    id: `evt_${ulid()}`,
    t: Date.now() - rand(0, 4 * 60000),
    type: 'econ.txn',
    src: 'bsd_banking',
    data: { player, direction: 'in', amount: base + (i % 7), source: 'unknown', balance_after: 0 },
  }));
}

// ---- Flush loop ----------------------------------------------------------
async function flush() {
  const events = Array.from({ length: rand(3, 12) }, makeEvent);
   if (Math.random() < 0.06) events.push(...dupeBurstEvents());
  const batch = {
    v: 1,
    server_id: CONFIG.serverId,
    seq: seq++,
    sent_at: Date.now(),
    agent: {
      version: '0.1.0-fake',
      artifact: '7290',
      resource_count: 142,
      uptime_s: Math.floor((Date.now() - bootedAt) / 1000),
    },
    events,
  };

  try {
    const res = await fetch(CONFIG.endpoint, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${CONFIG.token}`,
      },
      body: JSON.stringify(batch),
    });
    const body = await res.json();
    if (body.ok) {
      console.log(`[fake-agent] seq=${batch.seq} sent=${events.length} -> received=${body.received} deduped=${body.deduped}`);
    } else {
      console.error(`[fake-agent] REJECTED seq=${batch.seq}:`, JSON.stringify(body.error));
    }
  } catch (err) {
    console.error(`[fake-agent] network fail seq=${batch.seq}: ${err.message} (is server.js running?)`);
  }
}

// ---- Boot self-report ----------------------------------------------------
console.log('[fake-agent] BOOT OK');
console.log(`  target:   ${CONFIG.endpoint}`);
console.log(`  server:   ${CONFIG.serverId}`);
console.log(`  interval: ${CONFIG.flushIntervalMs}ms`);
flush();
setInterval(flush, CONFIG.flushIntervalMs);