// Sentinel fake agent — synthetic batch generator (wire protocol v1)
// Local (server.js in memory mode):   node agent/fake-agent.js
// Against a deployed backend, set these first (PowerShell: $env:NAME="value"):
//   SENTINEL_URL        e.g. https://api.blackstonescripts.com   (default http://localhost:3000)
//   SENTINEL_TOKEN      the token printed by npm run server:create
//   SENTINEL_SERVER_ID  the server_id printed with it
//
// This file is the reference implementation for the real Lua agent later —
// keep it honest to the spec.

const crypto = require('crypto');
const { ulid } = require('ulid');

const CONFIG = {
  endpoint: `${(process.env.SENTINEL_URL || 'http://localhost:3000').replace(/\/+$/, '')}/v1/ingest`,
  token: process.env.SENTINEL_TOKEN || 'dev_token_change_me',
  serverId: process.env.SENTINEL_SERVER_ID || 'srv_FAKE_LEGACY_RP',
  flushIntervalMs: 5000,
};

// Data contract Class I: raw licenses never leave the server. The agent sends
// an HMAC pseudonym keyed by a tenant key that is never transmitted.
const TENANT_KEY = crypto.randomBytes(32);
const pseudonym = (identifier) =>
  crypto.createHmac('sha256', TENANT_KEY).update(identifier).digest('hex').slice(0, 32);

const bootedAt = Date.now();
let seq = 0;

// ---- Synthetic event generators ------------------------------------------
const PLAYERS = ['Kaiden_R', 'Dev_Marcus', 'Mod_Sarah', 'Player_4471', 'Jess_T', 'BigMike'];
const RESOURCES = ['esx_inventory', 'es_extended', 'oxmysql', 'bsd_banking', 'bsd_machines'];
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];
const rand = (min, max) => Math.floor(Math.random() * (max - min + 1)) + min;

const STAFF = ['Mod_Sarah', 'Admin_Dave', 'Dev_Marcus', 'Mod_Kyle'];
const STAFF_ACTIONS = [
  { action: 'spawn_item',   detail: () => `${pick(['bandage','water','lockpick','repairkit'])} x${rand(1,10)}` },
  { action: 'teleport',     detail: () => `to ${pick(['hospital','pd','impound','airport'])}` },
  { action: 'revive',       detail: () => 'player revived' },
  { action: 'give_money',   detail: () => `$${rand(500, 250000).toLocaleString()}` },
  { action: 'ban',          detail: () => pick(['mod menu', 'RDM', 'exploiting', 'toxicity']) },
  { action: 'kick',         detail: () => pick(['AFK', 'mic spam', 'rule break']) },
  { action: 'set_job',      detail: () => pick(['police','ems','mechanic','unemployed']) },
];

function makeEvent() {
  const roll = Math.random();
  const base = { id: `evt_${ulid()}`, t: Date.now(), src: 'server' };

  if (roll < 0.30) {
    const player = pick(PLAYERS);
    return { ...base, type: 'player.join', data: {
      player,
      player_id: pseudonym(`license:${player.toLowerCase()}`),
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
  if (roll < 0.93) {
    const a = pick(STAFF_ACTIONS);
    // Admin_Dave is our problem child — he hands out money more than anyone
    const staffer = a.action === 'give_money' && Math.random() < 0.6 ? 'Admin_Dave' : pick(STAFF);
    return { ...base, type: 'staff.action', data: {
      staffer, action: a.action, target: pick(PLAYERS), detail: a.detail(),
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
        t: Date.now() - rand(0, 50_000),
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
    console.error(`[fake-agent] network fail seq=${batch.seq}: ${err.message} (is the backend up at ${CONFIG.endpoint}?)`);
  }
}

// ---- Boot self-report ----------------------------------------------------
console.log('[fake-agent] BOOT OK');
console.log(`  target:   ${CONFIG.endpoint}`);
console.log(`  server:   ${CONFIG.serverId}`);
console.log(`  interval: ${CONFIG.flushIntervalMs}ms`);
flush();
setInterval(flush, CONFIG.flushIntervalMs);