-- =============================================================================
-- bsd_sentinel_agent / server / scrub.lua
-- Data contract, agent side: before anything is queued, raw identifiers become
-- pseudonyms and secrets are blanked. The backend checks again and rejects any
-- event that still carries one, so this file is the first of two locks.
-- =============================================================================

SA = SA or {}

local tenantKey = nil

function SA.setTenantKey(keyBytes)
    tenantKey = keyBytes
end

--- HMAC-SHA256 pseudonym, 32 hex characters (Class I → pseudonymous).
function SA.pseudonym(identifier)
    if not tenantKey then error('tenant key not loaded before first pseudonym') end
    return SA.hmacHex(tenantKey, tostring(identifier)):sub(1, 32)
end

local IDENTIFIER_KINDS = {
    license = true, license2 = true, discord = true, steam = true,
    fivem = true, xbl = true, live = true, ip = true,
}

local DB_SCHEMES = {
    mysql = true, postgres = true, postgresql = true, mongodb = true, ['mongodb+srv'] = true,
}

local SECRET_KEY_NAMES = { 'api_key', 'api-key', 'apikey', 'token', 'secret', 'password', 'passwd',
    'sv_licensekey', 'steam_webapikey', 'rcon_password' }

local function isSecretKeyName(name)
    local lower = name:lower()
    for _, k in ipairs(SECRET_KEY_NAMES) do
        if lower == k or lower:sub(-#k) == k then return true end
    end
    return false
end

--- Scrub one string. Returns the cleaned string.
function SA.scrubString(s)
    if type(s) ~= 'string' or s == '' then return s end

    -- 1. Identifiers ("license:abc123...", "discord:1234...", "ip:1.2.3.4") → pid:<pseudonym>
    s = s:gsub('[Ii][Pp]:(%d+%.%d+%.%d+%.%d+)', function(addr)
        return 'pid:' .. SA.pseudonym('ip:' .. addr)
    end)
    s = s:gsub('([%a][%w]*):(%w+)', function(kind, value)
        if IDENTIFIER_KINDS[kind:lower()] and #value >= 6 then
            return 'pid:' .. SA.pseudonym(kind:lower() .. ':' .. value)
        end
    end)

    -- 2. Database URIs
    s = s:gsub('([%a%+]+)://[^%s"\']+', function(scheme)
        if DB_SCHEMES[scheme:lower()] then return '[redacted:db_uri]' end
    end)

    -- 3. Discord webhooks
    s = s:gsub('discord%.com/api/webhooks/%d+/[%w_%-]+', '[redacted:discord_webhook]')
    s = s:gsub('discordapp%.com/api/webhooks/%d+/[%w_%-]+', '[redacted:discord_webhook]')

    -- 4. Bearer tokens
    s = s:gsub('([Bb][Ee][Aa][Rr][Ee][Rr])(%s+)([%w%-%._~%+/=]+)', function(word, gap, tok)
        if #tok >= 16 then return word .. gap .. '[redacted]' end
    end)

    -- 5. key=value / key: value / cfg-style secrets. The replacement is short
    --    on purpose: a long placeholder would itself look like a secret value.
    s = s:gsub('([%w_%-]+)(%s*[:=]%s*["\']?)([^%s"\']+)', function(name, sep, value)
        if isSecretKeyName(name) and #value >= 4 then return name .. sep .. '***' end
    end)
    s = s:gsub('([%w_]+)(%s+["\']?)([^%s"\']+)(["\']?)', function(name, sep, value)
        local lower = name:lower()
        if (lower == 'rcon_password' or lower == 'sv_licensekey' or lower == 'steam_webapikey') and #value >= 4 then
            return name .. ' ***'   -- quotes dropped: '"***"' would itself read as a 4+ character value
        end
    end)

    -- 6. Discord bot tokens: three dot-separated base64 groups (24+ . 6 . 27+)
    s = s:gsub('([MN][%w]+)%.([%w_%-]+)%.([%w_%-]+)', function(a, b, c)
        if #a >= 24 and #b == 6 and #c >= 27 then return '[redacted:bot_token]' end
    end)

    -- 7. IP:port pairs
    s = s:gsub('%d+%.%d+%.%d+%.%d+:%d+', '[redacted:ip_port]')

    return s
end

--- Scrub every string inside an event's data table (returns a new table).
function SA.scrubData(value, depth)
    depth = depth or 0
    if depth > 6 then return nil end
    local t = type(value)
    if t == 'string' then return SA.scrubString(value) end
    if t ~= 'table' then return value end
    local out = {}
    for k, v in pairs(value) do
        out[k] = SA.scrubData(v, depth + 1)
    end
    return out
end
