-- =============================================================================
-- bsd_sentinel_agent / server / key.lua
-- The tenant key: 32 random bytes that turn licenses into pseudonyms.
--
-- It is created once, saved in this resource's data/ folder, and NEVER sent
-- anywhere. Sentinel only ever sees HMAC(key, identifier), so it cannot turn a
-- pseudonym back into a license. Deleting data/tenant.key on purpose breaks
-- every old pseudonym: that is the owner's kill switch (data contract).
-- =============================================================================

SA = SA or {}

local KEY_FILE = 'data/tenant.key'

-- Best source: the OS random generator. Linux hosts expose /dev/urandom to
-- FXServer's Lua; Windows hosts don't, so there is a weaker fallback below.
local function osRandomBytes(n)
    local ok, f = pcall(io.open, '/dev/urandom', 'rb')
    if not ok or not f then return nil end
    local bytes = f:read(n)
    f:close()
    if bytes and #bytes == n then return bytes end
    return nil
end

-- Fallback: hash together everything unpredictable we can reach. Good enough
-- that nobody can guess it, but weaker than the OS generator, so it is flagged.
local function mixedRandomBytes(n)
    local pool = {}
    for i = 1, 256 do
        pool[#pool + 1] = table.concat({
            tostring(os.time()), tostring(os.clock()), tostring(GetGameTimer()),
            tostring({}), tostring(math.random(0, 0x7fffffff)), tostring(collectgarbage('count')),
            tostring(i),
        }, '|')
        if i % 32 == 0 then Wait(0) end
    end
    pool[#pool + 1] = GetConvar('sv_hostname', '') .. GetConvar('sv_projectName', '')
    local seed = table.concat(pool, ';')
    local out = SA.sha256Raw(seed)
    while #out < n do out = out .. SA.sha256Raw(out .. seed) end
    return out:sub(1, n)
end

--- Load the key, or create and save one on first run.
--- @return string keyBytes, string source ("file" | "created:urandom" | "created:mixed"), string|nil warning
function SA.loadTenantKey()
    local stored = LoadResourceFile(SA.RESOURCE, KEY_FILE)
    if stored then
        local hex = SA.trim(stored)
        if hex:match('^%x+$') and #hex == 64 then
            return SA.fromHex(hex), 'file', nil
        end
        SA.warn('%s is not a 64-character hex key; ignoring it and creating a new one. Old pseudonyms will not match new ones.', KEY_FILE)
    end

    local bytes = osRandomBytes(32)
    local source, warning = 'created:urandom', nil
    if not bytes then
        bytes = mixedRandomBytes(32)
        source = 'created:mixed'
        warning = 'This host has no /dev/urandom (Windows), so the key was made from mixed timing sources. It is unguessable in practice; for the strongest key, put 64 random hex characters in data/tenant.key yourself and restart.'
    end

    local saved = SaveResourceFile(SA.RESOURCE, KEY_FILE, SA.toHex(bytes), -1)
    if not saved then
        warning = (warning and (warning .. ' ') or '') ..
            'Could not write ' .. KEY_FILE .. ' (does the data folder exist and is it writable?). The key will change on every restart, so the same player will get a new pseudonym each time.'
    end
    return bytes, source, warning
end

--- First 8 hex characters of SHA-256(key): lets the portal tell keys apart
--- without ever seeing one.
function SA.keyFingerprint(keyBytes)
    return SA.sha256Hex(keyBytes):sub(1, 8)
end
