// ingest/config.js
// Every setting the backend reads, in one place. Bad or missing values fall
// back to a documented default, and every fallback is recorded so the boot
// report can say exactly what was used (ARCH Rules 1 and 2).
//
// Environment variables:
//   PORT                  HTTP port (DigitalOcean sets this; local default 3000)
//   NODE_ENV              "production" on DigitalOcean
//   DATABASE_URL          Postgres connection string. Required in production.
//   DATABASE_CA_CERT      PEM CA certificate for the managed database (bind ${db.CA_CERT})
//   PORTAL_USER           portal login name (default "admin")
//   PORTAL_PASSWORD       portal login password (generated at boot if missing)
//   SENTINEL_WEBHOOK      Discord webhook for HIGH findings (optional)
//   RETENTION_EVENT_DAYS  raw event retention, capped at the data contract's 30
//   SENTINEL_DEV_TOKEN    memory mode only: the one accepted agent token

const crypto = require('crypto');

const CONTRACT_EVENT_DAYS = 30; // docs/data-contract.md: raw events 30 days

function loadConfig(env = process.env) {
  const fallbacks = [];
  const warnings = [];
  const isProd = env.NODE_ENV === 'production';

  let port = parseInt(env.PORT, 10);
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    if (env.PORT) fallbacks.push(`PORT "${env.PORT}" is not a valid port, using 3000`);
    port = 3000;
  }

  const databaseUrl = (env.DATABASE_URL || '').trim();
  // A CA pasted by hand often arrives with literal "\n"; the DO binding has real newlines.
  const databaseCaCert = (env.DATABASE_CA_CERT || '').replace(/\\n/g, '\n').trim();

  const portalUser = (env.PORTAL_USER || '').trim() || 'admin';
  if (!env.PORTAL_USER) fallbacks.push('PORTAL_USER unset, using "admin"');

  let portalPassword = env.PORTAL_PASSWORD || '';
  let portalPasswordGenerated = false;
  if (!portalPassword) {
    portalPassword = crypto.randomBytes(18).toString('base64url');
    portalPasswordGenerated = true;
    warnings.push('PORTAL_PASSWORD unset: generated a one-time password for this boot (see "portal pw" above). Set PORTAL_PASSWORD so it survives restarts.');
  } else if (portalPassword.length < 16) {
    warnings.push('PORTAL_PASSWORD is shorter than 16 characters. Use a long random password: the portal is on the public internet.');
  }

  let retentionDays = parseInt(env.RETENTION_EVENT_DAYS, 10);
  if (!Number.isInteger(retentionDays) || retentionDays < 1) {
    if (env.RETENTION_EVENT_DAYS) fallbacks.push(`RETENTION_EVENT_DAYS "${env.RETENTION_EVENT_DAYS}" invalid, using ${CONTRACT_EVENT_DAYS}`);
    retentionDays = CONTRACT_EVENT_DAYS;
  } else if (retentionDays > CONTRACT_EVENT_DAYS) {
    fallbacks.push(`RETENTION_EVENT_DAYS ${retentionDays} exceeds the data contract's ${CONTRACT_EVENT_DAYS} days, capped at ${CONTRACT_EVENT_DAYS}`);
    retentionDays = CONTRACT_EVENT_DAYS;
  }

  return {
    port,
    isProd,
    databaseUrl,
    databaseCaCert,
    portalUser,
    portalPassword,
    portalPasswordGenerated,
    discordWebhook: env.SENTINEL_WEBHOOK || '', // env only, never in code
    retentionDays,
    devToken: env.SENTINEL_DEV_TOKEN || 'dev_token_change_me',
    maxEvents: 500,
    recentEventCap: 20000,   // events kept in memory for the portal and detection
    detectionWindow: 4000,   // most recent events per server fed to detection
    fallbacks,
    warnings,
  };
}

module.exports = { loadConfig, CONTRACT_EVENT_DAYS };
