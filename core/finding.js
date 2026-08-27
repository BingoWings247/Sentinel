// core/finding.js
// Sentinel Finding Schema v1 — the one shape every producer emits.
// PURE: no Express, no DB, no clocks. See docs/finding-schema-v1.md.
//
// Exports:
//   FindingSchema        Zod schema (strict) for a v1 finding
//   validateFinding(f)   → { ok, finding } | { ok:false, error:{code,field,detail} }
//   normalizeLegacy(f)   econ-anomaly / hitch-diagnosis output → v1 finding
//   assertNoSecrets(str) → null | pattern name that matched (never the value)

const { z } = require('zod');

// ---- Enums ---------------------------------------------------------------
const SEVERITY = ['INFO', 'LOW', 'MEDIUM', 'HIGH', 'CRITICAL'];
const CONFIDENCE = ['LOW', 'MEDIUM', 'HIGH'];
const OWNER = ['player', 'server_owner', 'script_developer', 'platform', 'nobody'];
const STATUS = ['open', 'acknowledged', 'resolved', 'muted'];
const EVIDENCE_KIND = ['event', 'log_line', 'crash_field', 'metric', 'manifest', 'config'];
const PRIVACY_CLASS = ['A', 'N'];   // S and I are never present in a stored finding

// ---- Class S patterns (Data Contract §1, Appendix B) ---------------------
// Names only ever leave this module; matched values never do.
const SECRET_PATTERNS = [
  ['sv_licenseKey',        /sv_licenseKey\s*["']?\s*[A-Za-z0-9]{8,}/i],
  ['steam_webApiKey',      /steam_webApiKey\s*["']?\s*[A-Fa-f0-9]{16,}/i],
  ['rcon_password',        /rcon_password\s*["']?\s*\S{4,}/i],
  ['db_uri',               /\b(mysql|postgres(ql)?|mongodb(\+srv)?):\/\/[^\s"']+/i],
  ['discord_webhook',      /discord(app)?\.com\/api\/webhooks\/\d+\/[A-Za-z0-9_\-]+/i],
  ['discord_bot_token',    /\b[MN][A-Za-z\d]{23,}\.[\w-]{6}\.[\w-]{27,}\b/],
  ['bearer',               /\bBearer\s+[A-Za-z0-9\-._~+/]{16,}=*/i],
  ['generic_assignment',   /\b(api[_-]?key|apikey|token|secret|password|passwd)\s*[:=]\s*["']?[^\s"']{8,}/i],
  ['ip_port',              /\b(\d{1,3}\.){3}\d{1,3}:\d{2,5}\b/],
];

// Raw Class I identifiers must never appear in a stored finding either.
const IDENTIFIER_PATTERNS = [
  ['identifier', /\b(license2?|discord|steam|fivem|xbl|live|ip):[A-Za-z0-9]{6,}\b/i],
];

function assertNoSecrets(str) {
  if (typeof str !== 'string' || !str) return null;
  for (const [name, re] of SECRET_PATTERNS) if (re.test(str)) return name;
  for (const [name, re] of IDENTIFIER_PATTERNS) if (re.test(str)) return name;
  return null;
}

// ---- Schema --------------------------------------------------------------
const Ms = z.number().int().nonnegative();

const Evidence = z.object({
  kind: z.enum(EVIDENCE_KIND),
  ref: z.string().min(1).max(200),
  excerpt: z.string().max(200).optional(),
}).strict();

const Alternative = z.object({
  kind: z.string().min(1).max(40),
  detail: z.string().min(1).max(300),
  confidence: z.enum(CONFIDENCE),
  magnitude: z.number().optional(),
}).strict();

const Location = z.object({
  resource: z.string().max(120).nullable().optional(),
  file: z.string().max(240).nullable().optional(),
  line: z.number().int().nonnegative().nullable().optional(),
  event: z.string().max(160).nullable().optional(),
  model: z.string().max(120).nullable().optional(),
  module: z.string().max(120).nullable().optional(),
  offset: z.string().max(24).nullable().optional(),
  build: z.string().max(12).nullable().optional(),
  hash: z.string().max(80).nullable().optional(),
}).strict();

const FindingSchema = z.object({
  schema: z.literal(1),
  id: z.string().min(1).optional(),
  key: z.string().min(1).max(200),
  family: z.string().regex(/^[a-z]+(\.[a-z_]+)+$/, 'dotted lowercase family, e.g. crash.pool_full'),
  producer: z.object({
    tool: z.string().min(1).max(40),
    version: z.string().min(1).max(20),
    module: z.string().max(80).optional(),
  }).strict(),
  tenant: z.string().nullable(),

  severity: z.enum(SEVERITY),
  confidence: z.enum(CONFIDENCE),

  summary: z.string().min(1).max(160),
  cause: z.object({
    headline: z.string().min(1).max(160),
    detail: z.string().max(1000).optional(),
    refs: z.array(z.string().url()).max(5).optional(),
  }).strict(),
  location: Location.optional(),
  owner: z.enum(OWNER),
  owner_detail: z.string().max(300).optional(),
  fix: z.object({
    steps: z.array(z.string().max(300)).max(10),
    automated: z.boolean(),
    docs_url: z.string().url().optional(),
  }).strict().optional(),

  subject: z.object({
    player_id: z.string().max(64).nullable().optional(),
    player: z.string().max(80).nullable().optional(),
    staffer: z.string().max(80).nullable().optional(),
    resource: z.string().max(120).nullable().optional(),
  }).strict().optional(),
  window: z.object({ from: Ms, to: Ms }).strict().optional(),
  first_seen: Ms.optional(),
  last_seen: Ms.optional(),
  count: z.number().int().positive().default(1),

  evidence: z.array(Evidence).max(20).default([]),
  alternatives: z.array(Alternative).max(5).optional(),
  metrics: z.record(z.string(), z.number()).default({}),
  signature: z.object({ db_id: z.string(), version: z.number().int() }).strict().optional(),

  privacy: z.object({
    redacted: z.literal(true),
    classes: z.array(z.enum(PRIVACY_CLASS)).min(1),
  }).strict(),
  contract_version: z.string().min(1),
  detected_at: Ms,
  status: z.enum(STATUS).default('open'),
}).strict();

// ---- Validation with the privacy gate ------------------------------------
// Zod checks shape; this walks every string and refuses Class S / raw Class I.
function* stringsOf(obj, path = '') {
  if (typeof obj === 'string') { yield [path, obj]; return; }
  if (Array.isArray(obj)) { for (let i = 0; i < obj.length; i++) yield* stringsOf(obj[i], `${path}[${i}]`); return; }
  if (obj && typeof obj === 'object') for (const k of Object.keys(obj)) yield* stringsOf(obj[k], path ? `${path}.${k}` : k);
}

function validateFinding(input) {
  const parsed = FindingSchema.safeParse(input);
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    return { ok: false, error: { code: 'invalid_finding', field: issue.path.join('.'), detail: issue.message } };
  }
  for (const [path, s] of stringsOf(parsed.data)) {
    // subject.player_id is the pseudonym slot; it may legitimately look like an id, but never a raw one.
    const hit = assertNoSecrets(s);
    if (hit) return { ok: false, error: { code: 'privacy_violation', field: path, detail: `value matched ${hit} pattern` } };
  }
  return { ok: true, finding: parsed.data };
}

// ---- Legacy bridge -------------------------------------------------------
const CONTRACT_VERSION = '1.0';
const LEGACY_PRODUCER = { tool: 'agent-core', version: '0.1.0' };

function confidenceOf(c) {
  if (c === 'MED') return 'MEDIUM';
  return CONFIDENCE.includes(c) ? c : 'LOW';
}

function normalizeLegacy(f) {
  if (!f || typeof f !== 'object') throw new TypeError('normalizeLegacy: expected an object');
  if (f.schema === 1) return f; // already v1

  const family = f.family || f.type;
  const base = {
    schema: 1,
    key: f.key,
    family,
    producer: { ...LEGACY_PRODUCER, module: family },
    tenant: f.tenant ?? null,
    confidence: confidenceOf(f.confidence),
    summary: String(f.summary || '').slice(0, 160),
    evidence: (f.evidence || []).slice(0, 20).map((e) => (typeof e === 'string' ? { kind: 'event', ref: e } : e)),
    privacy: { redacted: true, classes: ['N'] },
    contract_version: CONTRACT_VERSION,
    detected_at: f.detected_at,
    status: f.status || 'open',
  };

  if (family === 'econ.anomaly') {
    const unsourced = f.unsourced_ratio ?? 0;
    return {
      ...base,
      severity: unsourced >= 0.5 ? 'HIGH' : 'MEDIUM',
      cause: {
        headline: `${Math.round(unsourced * 100)}% of the gain has no income source`,
        detail: `${f.txn_count} near-identical transactions, median $${Math.round(f.median_amount || 0)}, repetition ${f.repetition_ratio}`,
      },
      owner: 'server_owner',
      owner_detail: 'Review the player and the resource that credited the money; Sentinel does not act.',
      subject: { player: f.player ?? null, player_id: f.player_id ?? null },
      window: f.window,
      first_seen: f.window?.from,
      last_seen: f.window?.to,
      count: 1,
      metrics: {
        amount: f.amount ?? 0,
        txn_count: f.txn_count ?? 0,
        median_amount: f.median_amount ?? 0,
        repetition_ratio: f.repetition_ratio ?? 0,
        unsourced_ratio: unsourced,
      },
    };
  }

  if (family === 'perf.hitch_issue') {
    const [top, ...rest] = f.causes || [];
    const worst = f.worst_ms ?? 0;
    const resmon = top && top.kind === 'resmon';
    return {
      ...base,
      severity: worst >= 500 ? 'CRITICAL' : worst >= 200 ? 'HIGH' : 'MEDIUM',
      cause: {
        headline: top ? top.detail : 'No abnormal activity in the window; likely external (host, OS, disk)',
      },
      location: resmon ? { resource: top.resource ?? f.top_cause ?? null } : undefined,
      owner: resmon ? 'script_developer' : 'server_owner',
      owner_detail: resmon
        ? 'The named resource is spending the tick budget; profile it or report to its author'
        : 'Check host load, restarts, and player count around the window',
      window: { from: f.first_seen, to: f.last_seen },
      first_seen: f.first_seen,
      last_seen: f.last_seen,
      count: f.count ?? 1,
      alternatives: rest.slice(0, 5).map((c) => ({
        kind: c.kind, detail: c.detail, confidence: confidenceOf(c.confidence), magnitude: c.magnitude,
      })),
      metrics: { worst_ms: worst, hitch_count: f.count ?? 1 },
    };
  }

  // Unknown legacy family: keep it, mark it, never drop it.
  return {
    ...base,
    family: family || 'unknown.legacy',
    severity: 'INFO',
    cause: { headline: 'Legacy finding without a v1 mapping' },
    owner: 'nobody',
    count: f.count ?? 1,
  };
}

module.exports = {
  FindingSchema,
  validateFinding,
  normalizeLegacy,
  assertNoSecrets,
  SEVERITY, CONFIDENCE, OWNER, STATUS,
};
