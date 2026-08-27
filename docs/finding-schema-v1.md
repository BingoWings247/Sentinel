Sentinel Finding Schema — v1

Draft, August 26, 2026. The one shape every Sentinel producer emits: the crash parser, the log analyzer, the config linter, the dependency graph, the on-server agent's detection brains, and the SDK. If every tool speaks this, all of them feed one store, one portal, one Discord notifier, and one aggregate dataset.

A finding answers five questions, in this order, and a finding that can't answer one of them is not finished:

What happened — summary
Why — cause
Where — location
Who fixes it — owner
How sure are we — confidence (about the classification) and severity (about the consequences)

Confidence and severity are deliberately separate. A pool-full crash is HIGH confidence and HIGH severity. A single unsourced $200 transaction is LOW severity even if HIGH confidence. A hitch with no attributable cause is LOW confidence but might be CRITICAL severity.

The object
jsonc
{
  "schema": 1,
  "id": "fnd_01J6...",                 // ULID, assigned when stored (producers may omit)
  "key": "crash.pool_full:b3570:fivem.exe+64C24F",   // stable dedupe key, producer-defined
  "family": "crash.pool_full",         // dotted taxonomy, lowercase (was `type`)
  "producer": { "tool": "crash-parser", "version": "0.3.0", "module": "families/pool" },
  "tenant": null,                      // tenant id for agent findings; null for free tools

  "severity": "HIGH",                  // INFO | LOW | MEDIUM | HIGH | CRITICAL
  "confidence": "HIGH",                // LOW | MEDIUM | HIGH

  "summary": "Client crashed on pool exhaustion: <<unknown pool>> Size==200 after 106 min",
  "cause": {
    "headline": "Server streams more archetypes than the engine pool can hold",
    "detail": "Duplicate-archetype warnings ran the whole session; three players on different GPUs hit the same offset. This is server content, not client hardware.",
    "refs": ["https://docs.blackstonescripts.com/crash/pool-full"]
  },
  "location": {                        // every field optional; use what applies
    "resource": null, "file": null, "line": null,
    "event": null, "model": null,
    "module": "fivem.exe", "offset": "0x64C24F", "build": "3570",
    "hash": "fish-mockingbird-two"
  },
  "owner": "server_owner",             // player | server_owner | script_developer | platform | nobody
  "owner_detail": "Reduce streamed archetypes or split the offending MLO/vehicle pack",
  "fix": {
    "steps": [
      "Run the Assets scan to see which resources push TxdStore/archetype counts",
      "Remove or lazy-load the largest offenders and re-test with the same players"
    ],
    "automated": false,
    "docs_url": "https://docs.blackstonescripts.com/crash/pool-full"
  },

  "subject": {                         // what/who the finding is about (Class I as pseudonyms only)
    "player_id": null, "player": null, "staffer": null, "resource": null
  },
  "window": { "from": 1756170000000, "to": 1756176360000 },
  "first_seen": 1756170000000,
  "last_seen": 1756176360000,
  "count": 3,

  "evidence": [                        // ≤ 20 items; excerpts ≤ 200 chars, already redacted
    { "kind": "log_line", "ref": "CitizenFX.log:9278968", "excerpt": "<<unknown pool>> Pool Full, Size == 200" },
    { "kind": "crash_field", "ref": "exception.address", "excerpt": "0x0000000000000010 (write)" },
    { "kind": "event", "ref": "evt_01J6..." }
  ],
  "alternatives": [                    // ranked runner-up causes, if the producer has them
    { "kind": "flood", "detail": "net.rate spike on ox_inventory:useItem", "confidence": "LOW", "magnitude": 1200 }
  ],
  "metrics": { "worst_ms": 0, "session_min": 106 },   // family-specific numbers, flat
  "signature": { "db_id": "sig_pool_full_v2", "version": 4 },  // link into the signature DB, if any

  "privacy": { "redacted": true, "classes": ["A"] },  // producer asserts; ingest re-checks
  "contract_version": "1.0",
  "detected_at": 1756176400000,
  "status": "open"                     // open | acknowledged | resolved | muted (mutable in portal)
}
Rules
summary ≤ 160 characters, one sentence, no trailing period needed. It's what the Discord embed and the list view show.
cause is required. If the producer can't classify, emit family: "unknown.<artifact>", confidence: "LOW", owner: "nobody", cause.headline: "No matching signature", and set fix.steps to the case-submission instruction. Unknowns are findings too; they're how the signature DB grows.
owner is required and is one of the five values. owner_detail says what that party does. The point of this field is that a support staffer can read one line and know whether to fix the server, tell the player, or escalate to a script author.
evidence never contains Class S data and never contains raw Class I identifiers. Producers redact; ingest runs the same filter again and rejects the finding (with a privacy_violation code naming the field, never the value) if anything matches.
subject.player_id is the HMAC pseudonym; subject.player is the display name. Free-tool findings carry neither.
key is the dedupe handle. Same key on a later pass means update in place (refresh count, last_seen, evidence), which is how grouped issues work. Producers define keys so that "the same problem" maps to the same key: crash families key on build+module+offset, econ anomalies on player+minute-bucket, hitch issues on top cause.
family replaces the old type field. First segment is the domain (crash, log, config, deps, perf, econ, staff, assets, net, unknown), second is the specific family. Adding a family is adding a record to the signature DB and a doc page, not a code release.
metrics is a flat bag of numbers. No nesting, no strings. If it isn't a number it belongs in evidence, location, or cause.
Timestamps are ms epoch. window is when the problem happened; detected_at is when the producer noticed.
Migration of the two existing producers

core/finding.js ships normalizeLegacy() so nothing breaks today:

Legacy field (econ-anomaly / hitch-diagnosis)	v1
type	family
confidence: 'MED'	confidence: 'MEDIUM'
player (top-level)	subject.player
causes[] (hitch)	cause ← causes[0], alternatives ← causes[1..]
top_cause	cause.headline (with location.resource when the cause is resmon)
evidence: [eventId]	evidence: [{ kind: 'event', ref }]
amount, txn_count, median_amount, repetition_ratio, unsourced_ratio, worst_ms	metrics.*
(none)	severity — econ: HIGH if unsourced ≥ 0.5 else MEDIUM; hitch: by worst_ms (≥500 CRITICAL, ≥200 HIGH, else MEDIUM)
(none)	owner — econ: server_owner; hitch: script_developer when resmon-attributed, else server_owner
(none)	producer, privacy, contract_version, status

Both modules should be updated to emit v1 natively; normalizeLegacy() is the bridge until they are, and it's tested so the bridge can't silently drift.

What the schema does not contain
No raw identifiers, no IPs, no secrets (Data Contract §1).
No scores of scripts or authors. owner: script_developer says who can fix it; it isn't a grade.
No moderation verbs. A finding is never "ban" or "kick"; those aren't Sentinel's.
No free-text fields beyond summary, cause.*, owner_detail, fix.steps[], and evidence[].excerpt, and all of them pass the redaction filter at ingest.

Changes to any field name, enum, or rule above require schema: 2.
