-- =============================================================================
-- bsd_sentinel_agent / server / main.lua
-- Boot: read settings, load the tenant key, start collectors, link to Sentinel,
-- and print a self-report (ARCH Rule 1). The agent never stops the server:
-- every problem is reported in the console with what to do about it.
--
-- server.cfg (use `set`, never `sets` or `setr`, which would publish the token):
--   set sentinel_token "sst_..."                     required
--   set sentinel_url "https://api.blackstonescripts.com"   optional
--   set sentinel_debug "true"                        optional, chatty logging
--   ensure bsd_sentinel_agent
-- =============================================================================

SA = SA or {}

local DEFAULT_URL = 'https://api.blackstonescripts.com'

local function readSettings()
    local fallbacks = {}

    local token = SA.trim(GetConvar('sentinel_token', ''))

    local url = SA.trim(GetConvar('sentinel_url', ''))
    if url == '' then
        url = DEFAULT_URL
        fallbacks[#fallbacks + 1] = 'sentinel_url unset, using ' .. DEFAULT_URL
    end
    url = url:gsub('/+$', '')
    local isLocal = url:match('^http://localhost') or url:match('^http://127%.0%.0%.1')
    if not url:match('^https://') and not isLocal then
        fallbacks[#fallbacks + 1] = 'sentinel_url "' .. url .. '" is not https, using ' .. DEFAULT_URL
        url = DEFAULT_URL
    end

    SA.debugEnabled = GetConvar('sentinel_debug', 'false') == 'true'
    return { token = token, url = url, fallbacks = fallbacks }
end

local function hostOf(url)
    return url:match('^https?://([^/]+)') or url
end

local adapterName = nil

local function tryAdapter()
    if adapterName then return end
    adapterName = SA.startQbcoreAdapter()
    if adapterName then
        SA.info('Money adapter: %s (QBCore:Server:OnMoneyChange)', adapterName)
    end
end

CreateThread(function()
    local settings = readSettings()

    local key, keySource, keyWarning = SA.loadTenantKey()
    SA.setTenantKey(key)
    local fingerprint = SA.keyFingerprint(key)

    local collectors = SA.startCollectors()

    tryAdapter()
    if not adapterName then
        -- The framework may start after the agent; pick it up when it does.
        AddEventHandler('onResourceStart', function(res)
            if res == 'qbx_core' or res == 'qb-core' then
                Wait(500)
                tryAdapter()
            end
        end)
    end

    -- ---- Boot report -------------------------------------------------------
    SA.info('^2BOOT^7 v%s', SA.VERSION)
    SA.info('  backend:    %s', settings.url)
    SA.info('  key:        %s (fingerprint %s)', keySource, fingerprint)
    SA.info('  collectors: %s', table.concat(collectors, ', '))
    SA.info('  money:      %s', adapterName or 'no supported framework running yet (Qbox / QBCore); money events off')
    for _, f in ipairs(settings.fallbacks) do SA.info('  fallback:   %s', f) end
    if keyWarning then SA.warn(keyWarning) end

    if settings.token == '' then
        SA.error('sentinel_token is not set, so nothing is being sent. Add this line to server.cfg above "ensure %s", then restart the resource:', SA.RESOURCE)
        SA.error('    set sentinel_token "sst_..."   (get one with: npm run server:create -- "Name")')
        return
    end
    if not settings.token:match('^sst_') then
        SA.warn('sentinel_token does not start with "sst_"; it may be pasted wrong. Trying it anyway.')
    end

    -- The first event after linking is the agent's own boot record.
    SA.transport.onLinked = function()
        SA.emit('agent.boot', {
            agent_version = SA.VERSION,
            contract_version = '1.0',
            scopes = { 'players', 'resources', 'hitch', adapterName and 'econ' or nil },
            redaction = { secrets = true, identifiers = 'hmac' },
            key_fingerprint = fingerprint,
            key_source = keySource,
            config_used = { backend_host = hostOf(settings.url), flush_s = SA.transport.flushIntervalMs // 1000 },
            fallbacks_applied = #settings.fallbacks > 0 and settings.fallbacks or nil,
            money_adapter = adapterName,
        })
    end

    SA.startTransport(settings.url, settings.token)
end)

-- ---- Console status: `sentinel_status` (server console / txAdmin console only) --
RegisterCommand('sentinel_status', function(src)
    if src ~= 0 then return end
    local T = SA.transport
    SA.info('status: %s%s', T.state, T.serverId and (' as ' .. T.serverId) or '')
    SA.info('  queued %d · sent %d · last success %s', #T.queue, T.sent,
        T.lastOkAt and (os.time() - T.lastOkAt .. 's ago') or 'never')
    if T.lastError then SA.info('  last problem: %s', T.lastError) end
end, true)
