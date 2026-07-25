# bsd-ecosystem

A FiveM framework and domain module suite built by BlackStone Development.

**Status:** Early development. Nothing here is production-ready. Do not install on a live server.

---

## What this is

`bsd-ecosystem` is a monorepo containing the BSD framework and the domain modules that plug into it. Every resource shares a common design philosophy:

- **Server-authoritative always.** Clients request, server decides.
- **Observable by default.** Every significant action is recorded and queryable.
- **Reversible by design.** Mutations can be undone with full audit trail.
- **Silent failure forbidden.** Every fault produces a specific, actionable message.
- **Lifetime commitment.** Resources are designed to be installed once and retained for the life of the server.

The mission behind BSD is harm reduction. The FiveM ecosystem has historically treated security, observability, and correctness as premium features — available to well-funded communities with dedicated developers, absent or broken everywhere else. Kids, new server owners, and inexperienced developers have been the ones paying the cost of that culture. BSD exists to raise the floor for everyone, not just the ceiling for the well-resourced.

---

## Repository structure

```
bsd-ecosystem/
├── README.md                    -- this file
├── docs/                        -- shared documentation
│   └── sentinel/
│       └── SCOPE.md             -- bsd_sentinel v1.0 scope document
├── resources/                   -- individual FiveM resources
│   └── bsd_sentinel/            -- observability and security operations layer
└── _archive/                    -- superseded work preserved for reference
    └── v0-prototype/            -- pre-pivot framework + banking work
```

Additional resources will be added here over time. Each resource directory is a self-contained FiveM resource that can be loaded via `server.cfg`.

---

## What's active

### `bsd_sentinel`

**Status:** Under active development. v1.0 in progress.

The observability and security operations layer for the BSD ecosystem — a unified event log, forensic investigation interface, and (in v1.1) anomaly detection engine that every BSD domain module writes to.

Sentinel is foundational. It has no BSD dependencies. Every domain module depends on it. It is the first resource in the ecosystem, and the only one not pending other work.

See `docs/sentinel/SCOPE.md` for the complete v1.0 specification.

---

## What's parked

### `bsd_banking` v2

**Status:** Design parked until `bsd_sentinel` v1.0 ships.

A banking rebuild covering personal finance, business accounts, municipal treasury, department budgets, and audit infrastructure. Research and partial decisions are preserved in `docs/BANKING_V2_NOTES.md`. Do not build from those notes — they are reference material, not a scope document.

Banking v2 design will resume once Sentinel is running on a test server with 30+ days of real event data. The banking rebuild's event model, correlation patterns, and audit requirements depend on Sentinel's production behavior, which is not yet known.

### `bsd_fuel` v2

**Status:** Design parked until `bsd_banking` v2 ships.

The current `bsd_fuel` (preserved under `_archive/v0-prototype/`) has known critical bugs including a PIN bypass, a cancel-refund gap, and an orphaned fleet authorization hook. It is not safe to install. A v2 rebuild will come after banking v2 is complete, at which point fuel can be rebuilt with real merchant accounts, functional fleet card routing to department budgets, and proper audit trail emission to Sentinel.

---

## Build order

The ecosystem builds bottom-up. Infrastructure first, domain modules on top.

1. `bsd_sentinel` v1.0 — observability foundation. **(In progress.)**
2. `bsd_banking` v2 — financial/treasury layer, on top of Sentinel.
3. `bsd_fuel` v2 — first domain module, on top of both.
4. Future domain modules: medical, LEO, fleet, CAD, stockmarket, etc.

Each resource ships only when it meets its quality gate. No due dates. Quality is the constraint.

---

## Working philosophy

**There is no due date.** Resources ship when they are correct, not when a calendar says so. The cost of over-engineering infrastructure is paid once by the developer. The cost of under-engineering is paid forever by the operators and players who depend on it.

**Lifetime commitment.** Every schema decision, every API signature, every config key name is effectively permanent. Operators who install v1.0 must be able to upgrade through the entire 1.x line without manual migration, config rewrites, or broken domain modules.

**The answer is in the tool, not the forum.** When something goes wrong, the server owner should get a clear, actionable answer from a single command — not a link to a dead forum thread. This principle drives error messages, command output, documentation, and alert design.

**Default to safe, not powerful.** Out-of-box configuration protects the operator from themselves. Advanced configuration is available for those who know what they're doing.

---

## Development

### Prerequisites

- FiveM server artifacts (recent stable recommended)
- `oxmysql` resource
- MySQL 8.0+ or MariaDB 10.5+
- (Optional but recommended) `ox_lib` for enhanced utilities

### Testing

Nothing in this repository should currently be installed on a production server. Testing happens on isolated development servers. Private beta comes after Sentinel v1.0 is complete.

### Contribution

This is a private repository during initial development. When BSD is ready for community contributions, contribution guidelines will be added.

---

## Licensing

License terms will be finalized before the first public release. Nothing in this repository is currently licensed for redistribution.

---

## Contact

BlackStone Development — `blackstonescripts.com`

---

*"Protect people from evil wherever it exists — and sometimes, protect people from themselves."*
