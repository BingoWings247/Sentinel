# Sentinel

Server observability for FiveM and RedM, by BlackStone Development.
Source-available, all rights reserved: see `license.txt`.

A thin agent on each game server batches events to this backend; the backend
stores them in Postgres, runs detection, sends Discord alerts and serves the portal.

```
ingest/server.js        HTTP server: POST /v1/ingest (agents), portal + read API (people)
ingest/config.js        every environment variable, with logged fallbacks
ingest/db-postgres.js   Postgres storage + migrations (runs them at boot)
ingest/db-memory.js     local-development stand-in when DATABASE_URL is unset
ingest/migrations/      numbered SQL migrations; never edit one that has shipped
ingest/auth.js          agent bearer tokens, portal login (HTTP Basic until Clerk)
ingest/privacy.js       data-contract gate: secrets and raw identifiers are rejected
core/                   detection modules (pure: events in, findings out)
agent/fivem/bsd_sentinel_agent/   the FiveM agent resource (see its README to install)
agent/fivem/test/run.lua          agent crypto + scrubber tests: lua agent/fivem/test/run.lua
agent/fake-agent.js     synthetic agent for testing without a game server
scripts/servers.js      link / list / revoke game servers
portal/                 the portal pages
docs/                   wire protocol, data contract, finding schema
.do/app.yaml            DigitalOcean App Platform spec
```

## Run it locally

```powershell
npm install
npm start                 # no DATABASE_URL: in-memory mode, data lost on restart
npm run fake-agent        # second terminal
```

The boot report prints a one-time portal password; open http://localhost:3000
and log in as `admin` with it. Set `PORTAL_PASSWORD` to keep one.

## Tests

```powershell
npm test                  # Postgres tests are skipped without TEST_DATABASE_URL
$env:TEST_DATABASE_URL="postgres://postgres@127.0.0.1:5432/postgres"; npm test
```

The Postgres tests create a throwaway database and drop it. Never point
`TEST_DATABASE_URL` at the production database.

## Deploy to DigitalOcean

The database already exists. In the DigitalOcean console:

1. **Apps → Create App → GitHub**, repo `BingoWings247/sentinel`, branch `main`, autodeploy on.
2. It detects Node.js. Keep the web service; run command `npm start`, HTTP port `8080`.
3. **Attach the existing database** to the app and name the component `sentinel-db`.
4. **Environment variables** on the web service:

   | Key | Value |
   |---|---|
   | `NODE_ENV` | `production` |
   | `DATABASE_URL` | `${sentinel-db.DATABASE_URL}` |
   | `DATABASE_CA_CERT` | `${sentinel-db.CA_CERT}` |
   | `PORTAL_USER` | `admin` (or your choice) |
   | `PORTAL_PASSWORD` | a long random password, **Encrypt** ticked |
   | `SENTINEL_WEBHOOK` | optional Discord webhook URL, **Encrypt** ticked |

   Don't add `PORT`; App Platform sets it.
5. Same region as the database (SFO), smallest plan, **Create**.
6. **Runtime Logs** should show `BOOT OK`, `migrations: applied 001_init.sql`
   and `TLS verified against DATABASE_CA_CERT`. Anything else is printed as a
   specific `BOOT FAILED` reason.
7. Set the health check path to `/healthz` (Settings → web → Health Checks).
8. On the database, **Trusted Sources** should list the app. If it doesn't, add it.

`.do/app.yaml` describes the same app if you'd rather create it from a spec;
change `cluster_name` first.

### Link a game server

In the app's **Console** tab (DATABASE_URL is already set there):

```
npm run server:create -- "My RP Server"
```

It prints a `server_id` and a token **once**. Only the token's hash is stored.
`npm run server:list` shows linked servers; `npm run server:revoke -- srv_...`
cuts one off.

### Connect a FiveM server

Follow `agent/fivem/bsd_sentinel_agent/README.md`: copy the folder into the
server's resources, add `set sentinel_token "sst_..."` to `server.cfg`, ensure it.

### Point the fake agent at it

```powershell
$env:SENTINEL_URL="https://<your-app>.ondigitalocean.app"
$env:SENTINEL_TOKEN="sst_..."
$env:SENTINEL_SERVER_ID="srv_..."
npm run fake-agent
```

## Environment variables

| Variable | Default | Notes |
|---|---|---|
| `DATABASE_URL` | none | Required when `NODE_ENV=production`; unset locally means memory mode |
| `DATABASE_CA_CERT` | none | Without it the database link is encrypted but unverified, with a warning |
| `PORTAL_USER` / `PORTAL_PASSWORD` | `admin` / generated | Generated passwords change every restart |
| `SENTINEL_WEBHOOK` | none | Discord alerts for findings that pass the alert rules |
| `RETENTION_EVENT_DAYS` | 30 | Capped at the data contract's 30 days |
| `SENTINEL_DEV_TOKEN` | `dev_token_change_me` | Memory mode only |

## Not built yet

- Server binding (IP + port lock) and self-service rebind: the columns exist, enforcement doesn't.
- Accounts and teams (Clerk); until then the portal shows every linked server together.
- Per-resource CPU time in the agent, ESX money events, and RedM.
