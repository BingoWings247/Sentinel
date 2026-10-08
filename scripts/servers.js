// scripts/servers.js — link, list and revoke game servers.
//
//   npm run server:create -- "My RP Server"   prints a NEW token once; save it
//   npm run server:list
//   npm run server:revoke -- srv_XXXXXXXX     the agent gets auth_failed from then on
//
// Needs DATABASE_URL (and DATABASE_CA_CERT for a managed database). On
// DigitalOcean, run it from the app's Console tab, where both are already set.

const { loadConfig } = require('../ingest/config');
const { createPostgresStore } = require('../ingest/db-postgres');

async function main() {
  const [cmd, ...args] = process.argv.slice(2);
  const config = loadConfig();
  if (!config.databaseUrl) {
    console.error('DATABASE_URL is not set. Run this where the app runs (DigitalOcean Console tab),');
    console.error('or set DATABASE_URL and DATABASE_CA_CERT in this terminal first.');
    process.exit(1);
  }
  const db = createPostgresStore({ databaseUrl: config.databaseUrl, caCert: config.databaseCaCert });
  try {
    await db.init(); // a fresh database gets its tables here too

    if (cmd === 'create') {
      const name = args.join(' ').trim();
      if (!name) throw new Error('give the server a name: npm run server:create -- "My RP Server"');
      if (name.length > 80) throw new Error('server name is longer than 80 characters');
      const s = await db.createServer(name);
      console.log('');
      console.log(`  Server linked: ${s.name}`);
      console.log(`  server_id:     ${s.id}`);
      console.log(`  token:         ${s.token}`);
      console.log('');
      console.log('  The token is shown ONCE and is not stored anywhere, only its hash.');
      console.log('  Put both values in the agent config. Lost it? Revoke and create again.');
      console.log('');
    } else if (cmd === 'list') {
      const rows = await db.listServers();
      if (!rows.length) console.log('No servers linked yet. npm run server:create -- "Name"');
      for (const r of rows) {
        const state = r.revoked_at ? 'REVOKED' : r.last_seen_at ? `last seen ${r.last_seen_at.toISOString()}` : 'never connected';
        console.log(`${r.id}  ${r.token_hint}…  ${r.name}  (${state})`);
      }
    } else if (cmd === 'revoke') {
      const id = (args[0] || '').trim();
      if (!id.startsWith('srv_')) throw new Error('give the server_id to revoke: npm run server:revoke -- srv_XXXXXXXX');
      const ok = await db.revokeServer(id);
      console.log(ok ? `Revoked ${id}. Its agent will get auth_failed from the next batch.` : `${id} not found or already revoked.`);
    } else {
      console.log('Usage: npm run server:create -- "Name" | npm run server:list | npm run server:revoke -- srv_ID');
    }
  } finally {
    await db.close();
  }
}

main().catch((err) => {
  console.error(`servers: ${err.message}`);
  process.exit(1);
});
