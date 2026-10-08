-- 001_init.sql — Sentinel backend schema, first version.
-- Applied once by ingest/db-postgres.js at boot; never edit after it ships.
-- Later changes go in 002_*.sql and onward.

-- One row per linked game server. The agent's bearer token is never stored,
-- only its SHA-256, so a database leak doesn't hand out working tokens.
CREATE TABLE servers (
  id            text        PRIMARY KEY,           -- srv_...
  name          text        NOT NULL,
  token_hash    text        NOT NULL UNIQUE,       -- sha256 hex of the bearer token
  token_hint    text        NOT NULL,              -- first characters, for display only
  bound_ip      inet,                              -- server binding (IP lock), not enforced yet
  bound_port    integer,
  created_at    timestamptz NOT NULL DEFAULT now(),
  revoked_at    timestamptz,
  last_seen_at  timestamptz,
  last_seq      bigint,
  last_agent    jsonb
);

-- Raw wire-protocol events. (server_id, id) is the idempotency key, so a
-- retried batch is free and one server can never collide with another.
-- Retention: 30 days by received_at (docs/data-contract.md).
CREATE TABLE events (
  server_id    text        NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
  id           text        NOT NULL,
  t            bigint      NOT NULL,                -- agent clock, ms epoch
  type         text        NOT NULL,
  src          text        NOT NULL,
  data         jsonb       NOT NULL,
  received_at  timestamptz NOT NULL DEFAULT now(),  -- backend clock
  PRIMARY KEY (server_id, id)
);
CREATE INDEX events_received_idx ON events (received_at);
CREATE INDEX events_server_type_t_idx ON events (server_id, type, t DESC);

-- Findings live for the life of the tenant. body is the finding as produced
-- by the detection module; key is that module's dedupe key.
CREATE TABLE findings (
  server_id    text        NOT NULL REFERENCES servers(id) ON DELETE CASCADE,
  key          text        NOT NULL,
  type         text        NOT NULL,
  confidence   text        NOT NULL,
  body         jsonb       NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (server_id, key)
);
CREATE INDEX findings_updated_idx ON findings (updated_at DESC);

-- Every alert decision, delivered or not, so "why didn't I get pinged?" has an answer.
CREATE TABLE alerts (
  id          bigserial   PRIMARY KEY,
  server_id   text        REFERENCES servers(id) ON DELETE CASCADE,
  at          timestamptz NOT NULL DEFAULT now(),
  type        text        NOT NULL,
  confidence  text        NOT NULL,
  summary     text        NOT NULL,
  key         text,
  status      text        NOT NULL
);
CREATE INDEX alerts_at_idx ON alerts (at DESC);

-- Small runtime settings, such as alert rules edited from the portal.
CREATE TABLE settings (
  key         text        PRIMARY KEY,
  value       jsonb       NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
