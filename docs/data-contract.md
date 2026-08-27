Sentinel Data Contract

Version 1.0 — draft, August 26, 2026 — BlackStone Development

This document is two things at once: the public promise at blackstonescripts.com/data, and the engineering constraint every Sentinel component is built against. If code and this document disagree, the code is the bug.

It is written in plain language on purpose. If a rule can't be stated plainly, it isn't a rule yet.

0. Who this covers and what the words mean
Term	Meaning
BlackStone / we	BlackStone Development, operator of Sentinel and the free tools.
Owner	The person or team who links a FiveM/RedM server to Sentinel. The owner controls what their server sends and can end it at any time.
Player	Anyone who connects to an owner's server. Players never have a relationship with us; their data reaches us only through the owner's server, and the owner is responsible for telling players it does.
Tenant	One linked server and everything stored for it. Nothing crosses tenants.
Artifact	Something a person hands a free tool: a crash zip, a CitizenFX.log, a server console log, a server.cfg, a profiler JSON, a resource folder.
Finding	The structured result of analysis: what happened, why, where, who fixes it, how confident we are. Findings are the only thing Sentinel is trying to produce.
Pseudonym	A stable, one-way stand-in for a player identifier, computed on the owner's server with a key we never hold.
1. The four classes of data

Every field that could ever pass through Sentinel belongs to exactly one class. The class decides the rule. A field with no class is not allowed to exist.

Class S — Secrets. Never transmitted. Never stored.

Server license keys (sv_licenseKey), Steam Web API keys, Cfx keymaster tokens, database connection strings and passwords, Discord bot tokens, Discord webhook URLs, txAdmin credentials, any rcon_password, API keys for third-party resources, and anything else that grants access to something.

The browser tools strip these before any byte leaves the browser.
The agent never reads server.cfg or any file, and never emits a field that could hold one.
The backend rejects and discards, without logging, any value matching a secret pattern that arrives anyway.
If a secret ever reaches our storage through a bug, that is a security incident under §8, and the owner is told.
Class I — Player identifiers. Pseudonymized on the owner's server. Never reversible by us.

license:, license2:, discord:, steam:, fivem:, xbl:, live:, ip: identifiers, hardware tokens, and player IP addresses.

The agent replaces every identifier with an HMAC-SHA256 pseudonym keyed with a tenant key generated on the owner's server at link time and stored only there. We never see the key. The same player always maps to the same pseudonym within one tenant, and to nothing across tenants.
Player IP addresses are not sent at all, pseudonymized or otherwise. Sentinel has no use for them.
Resolving a pseudonym back to a real player happens only on the owner's server, through the agent, on a staff request made in-game or via the portal's piggybacked command channel. The answer is shown, not stored.
If an owner deletes their tenant key, every pseudonym we hold for that tenant becomes permanently meaningless. That is the intended kill switch.
Class N — Names and server metadata. Stored, tenant-scoped, encrypted at rest.

Player display names (in-game character or account names as the server sees them), staff display names, resource names, event names, model names, vehicle plates, amounts, timestamps, hitch durations, artifact/build versions, agent version, resource counts, and free-text reason strings from drops, bans, and staff actions.

Stored per tenant, encrypted at rest with a key that is unique to that tenant and is never stored in code or in the database.
Free-text fields (reason, detail) are passed through a secret filter (Class S patterns) before storage, because txAdmin and other tools sometimes put things in reasons that don't belong there.
Never shown outside the tenant. Never used in published aggregates in any form that could identify a server or player.
Class A — Aggregate and technical. Stored, may be published under §6.

Crash signatures (build, module, offset, human-hash, exception code), finding families and confidence, resource names seen across servers, pool ceilings and pressure measurements, hitch cause rankings, artifact version distributions, adapter and framework in use.

This is what makes Error Intelligence improve. It is technical data about software, not about people.
Published only as aggregates that meet the threshold in §6.
2. The free hosted tools (crash parser, log analyzer, config linter, dependency graph)
Parsing happens in your browser. Artifacts are read and analyzed locally. Nothing is uploaded by default. Closing the tab destroys everything.
Redaction happens before sharing, not after. If you choose Share, the browser applies the Class S strip and Class I pseudonymization (with a random per-share key that is discarded) before any upload. What you see in the share preview is exactly what we receive.
We store the finding, not the artifact. A shared report contains the structured finding, the matched signature, and a redacted excerpt of at most the log lines the finding cites. The full log, dump, or config is never stored.
Share links are public by design. Anyone with the link can read the redacted report. Don't share what you wouldn't post on the CFX forum. Share pages can be deleted by anyone holding the link's delete token, which is shown once at share time.
Unknown cases become cases. If the parser can't classify an artifact and you choose Submit as unknown, the same redaction applies, and the case is stored for signature research. It is never shown publicly until it becomes a named family.
Minidumps stay local. The browser reads the minidump to extract module, offset, and exception. The dump file itself is never uploaded, even on share, because it can contain memory contents we have no way to classify.
3. The on-server agent

Sends: the event types in the wire protocol registry, and only those. Every batch is validated against a schema at the door; anything not in the schema is rejected with a named reason. Unrecognized event types from third-party SDK users are stored raw but pass through the same Class S filter.

Never sends: Class S, player IPs, file contents, server.cfg, chat messages, voice, positions/coordinates, screenshots, or anything the agent has not been explicitly coded to emit. The agent has no file-read scope except the resources folder listing needed for the Assets scanner, and that scope is announced in agent.boot (scopes: [...]) so the owner sees it every start.

Direction: outbound only. The agent opens every connection. There is no inbound port, no listener, and no way for our backend to execute anything on the owner's server. Portal-to-agent commands ride back in the response to the agent's own batch and are limited to a small, documented command set published with the agent's source.

Authentication: a per-server bearer token issued at link time, shown once, stored on our side as a hash. Rotatable and revocable from the portal instantly. Subscription lapse revokes it; the agent stops sending and says so in the server console.

Self-reporting: on every boot the agent emits agent.boot with its version, its redaction configuration, the scopes it has, and the pseudonymization key fingerprint (not the key). If redaction is misconfigured the agent refuses to send and reports why. This is ARCH Rule 1 applied to privacy.

Open source. The agent's code is public so any owner can verify these statements against what actually runs.

4. The SDK

Third-party developers who integrate Sentinel.Error(), Sentinel.Metric(), and friends are bound by this contract as a condition of the SDK license:

The SDK offers no method that accepts a raw identifier; player references must go through the agent's pseudonymizer.
The SDK rejects payloads that match Class S patterns and logs a warning naming the resource, so a developer who leaks a key learns about it from their own console before we ever see it.
A developer's telemetry is visible to the server owner whose server produced it, and to the developer only for their own resource and only in aggregate across servers, never per-player.
5. What the backend stores and how
Property	Rule
Hosting	The application and database run on a managed cloud provider; the static site, docs, and browser tools are served from a separate CDN so that the free tools never touch the systems that hold tenant data. Encrypted backups are kept with a second provider so no single account failure can lose them. Named providers are listed in the Privacy Policy and Data Processing Terms.
Tenant isolation	Every query is scoped by tenant at the data layer, not the UI. There is no "all tenants" query path in the portal.
Encryption	TLS in transit everywhere. Class N encrypted at rest with a separate key per tenant; keys are never stored in code, in the database, or alongside the data they protect. Tokens stored hashed. Backups encrypted before they leave the primary provider.
Retention — events	Raw events: 30 days. Daily rollups per resource/event type: 13 months. Findings: life of the tenant. Asset snapshots: 90 days nightly plus recent incrementals.
Retention — free tools	Shared reports: until deleted by holder of the delete token, or 12 months of no views. Unknown-case submissions: until classified or 12 months.
Deletion	Owner deletes tenant → all Class N and I data purged within 7 days, backups age out within 35. Class A aggregates that can no longer be traced to the tenant remain.
Access on our side	One operator today. Every read of tenant data from an administrative path is written to an audit log the owner can see. No support access without the owner's ticket.
Subprocessors	Hosting, CDN/DNS, identity, billing, and alert delivery are each provided by a named third party. The current list lives in the Privacy Policy and Data Processing Terms, where the law requires it. Adding one requires a contract version bump and 30 days' notice.
Logs	Application logs never contain request bodies, tokens, or Class I/N values. Log lines carry tenant ID and event counts only.
6. Aggregates and publishing

We intend to publish aggregate findings ("what crashed in FiveM this month and why"). Rules:

A statistic is published only when it draws on at least 10 distinct tenants or at least 25 distinct share submissions, whichever applies.
Aggregates name software (resources, builds, modules, families), never servers, owners, staff, or players.
Resource names appear in aggregates only when the finding is about the resource's behavior (a crash family, a pool footprint), never as a ranking or score of the resource or its author.
Any owner can opt their tenant out of aggregates entirely from the portal, with no loss of function.
7. Owners' responsibilities and players' rights
The owner is the party who decides to collect player data and send it to Sentinel. We process it on the owner's behalf. Owners should say so in their server rules or privacy notice; we provide a sentence they can paste.
Players may ask an owner what Sentinel holds about them. The owner resolves their pseudonym locally and can export or purge that player's tenant data from the portal.
Where owners operate under GDPR, UK GDPR, or similar laws, the Data Processing Terms (a separate document) govern; this contract is the technical description they refer to.
8. When something goes wrong
We treat any suspected exposure of Class S or Class I data as a security incident.
Affected owners are notified within 72 hours of confirmation with what was exposed, when, what we did, and what they should do.
A public post-incident summary follows within 30 days.
Security researchers can report issues to the address in /.well-known/security.txt. We will not take legal action against good-faith research that respects owners' data.
9. What Sentinel is not

This section exists so the suggestions tab can point at it.

Not an anticheat. It surfaces provenance-based anomalies for humans to judge. It does not score players, predict cheating, or auto-ban.
Not a management tool. No kick, ban, console, or command execution. txAdmin does that.
Not a licence or piracy detector. The Assets scanner measures engine load; it never adjudicates whether content is legitimate.
Not a place for chat, voice, positions, or screenshots. None are collected.
Not a leaderboard of developers. No public scores of scripts or their authors are derived from tenant data.

Requests to add any of the above will be declined with a link here.

10. Changing this contract
This document is versioned. Every change ships with a changelog entry and a diff.
Changes that collect more data, add a subprocessor, or lengthen retention take effect 30 days after notice to owners by email and in the portal. Changes that collect less take effect immediately.
The agent reports the contract version it was built against in agent.boot; the portal shows it, so an owner always knows which promises their running agent honors.

The engineering changes this contract requires are tracked in docs/data-contract-engineering.md (internal). Questions about this document: security@blackstonescripts.com. It will change. That's the point of versioning it.
