# bsd_sentinel_agent

The Sentinel agent for FiveM. It runs server-side only, watches your server and
sends what it sees to Sentinel. It never changes anything in the game.

## Install

1. Copy this `bsd_sentinel_agent` folder into your server's `resources` folder.
2. In `server.cfg`, **after** your framework (`ensure qbx_core` or `ensure qb-core`):

   ```cfg
   set sentinel_token "sst_..."
   set sentinel_url "https://api.blackstonescripts.com"
   ensure bsd_sentinel_agent
   ```

   Use `set`. Never `sets` or `setr`: those publish the value to the server
   list and to players, which would give away your token.
3. Restart the server, or in the server console: `refresh` then `ensure bsd_sentinel_agent`.

The token comes from Sentinel's console: `npm run server:create -- "Server name"`.
The agent looks up its own server ID from the token, so the token is the only
thing to paste.

## Check it's working

The server console shows a boot report:

```
[sentinel-agent] BOOT v0.1.0
[sentinel-agent]   backend:    https://api.blackstonescripts.com
[sentinel-agent]   key:        created:urandom (fingerprint 1a2b3c4d)
[sentinel-agent]   collectors: players, resources, hitch
[sentinel-agent]   money:      qbox
[sentinel-agent] Linked to Sentinel as "Server name" (srv_...).
```

Type `sentinel_status` in the server console at any time for the link state,
queue size and last successful send. Add `set sentinel_debug "true"` to see every batch.

Anything wrong is printed with what to do about it: a missing or rejected
token, an unreachable backend (events buffer and retry), or an event Sentinel refused.

## What it sends

| Event | When |
|---|---|
| `agent.boot` | The agent links to Sentinel |
| `player.join` / `player.drop` | A player connects or leaves, with the drop reason |
| `server.resource` | A resource starts or stops; a stop within 10 s of starting is flagged as a likely crash loop |
| `server.hitch` | The server thread stalls for 250 ms or more |
| `econ.txn` / `econ.set` | Money is added, removed or set (Qbox and QBCore) |

Players are identified by a **pseudonym**, never their license, Discord ID or
IP. The agent turns identifiers into pseudonyms with a key kept in
`data/tenant.key`, which is created on first start and never leaves this server.
Back that file up with your server: if it's lost, players get new pseudonyms
and their history in Sentinel stops linking up.

Secrets that turn up in text (webhook URLs, database URLs, passwords,
tokens, IP:port pairs) are blanked before sending, and Sentinel checks again.

## Money provenance

On Qbox and QBCore every `AddMoney`, `RemoveMoney` and `SetMoney` call is
recorded with the `reason` the calling script passed. Money with no reason is
recorded as source `unknown`: that's what Sentinel's dupe detection looks for,
so scripts that pass a reason make their money traceable.

## Not yet

- Per-resource CPU time (resmon): FXServer doesn't expose it to server Lua,
  so hitch causes come from resource starts/stops and event floods for now.
- ESX and other frameworks' money events.
- RedM.
