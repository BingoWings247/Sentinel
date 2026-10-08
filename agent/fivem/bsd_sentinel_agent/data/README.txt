This folder holds tenant.key, created by the agent on first start.

tenant.key turns player licenses into pseudonyms before anything leaves this
server. It is never sent to Sentinel. Keep it with your server backups:
if it is deleted, the same players get new pseudonyms and their history in
Sentinel no longer links up. Deleting it on purpose is how you cut that link.

Never commit it to a public repository.
