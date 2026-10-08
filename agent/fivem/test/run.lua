-- agent/fivem/test/run.lua — checks the agent's crypto and scrubber in plain Lua 5.4.
-- No FXServer needed. From the repo root:   lua agent/fivem/test/run.lua

local SERVER = 'agent/fivem/bsd_sentinel_agent/server/'
GetCurrentResourceName = function() return 'bsd_sentinel_agent' end
GetGameTimer = function() return 0 end
dofile(SERVER .. 'sha256.lua')
dofile(SERVER .. 'util.lua')
dofile(SERVER .. 'scrub.lua')

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1 else failed = failed + 1; print('FAIL ' .. name .. (detail and ('  :: ' .. detail) or '')) end
end
local function eq(name, got, want) check(name, got == want, ('got %q want %q'):format(tostring(got), tostring(want))) end

-- SHA-256 (FIPS 180-2) and HMAC-SHA256 (RFC 4231)
eq('sha256 empty', SA.sha256Hex(''), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855')
eq('sha256 abc', SA.sha256Hex('abc'), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad')
eq('sha256 two blocks', SA.sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'),
    '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1')
eq('hmac rfc4231 #1', SA.hmacHex(string.rep('\x0b', 20), 'Hi There'),
    'b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7')
eq('hmac rfc4231 #2', SA.hmacHex('Jefe', 'what do ya want for nothing?'),
    '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843')
eq('hmac rfc4231 #6', SA.hmacHex(string.rep('\xaa', 131), 'Test Using Larger Than Block-Size Key - Hash Key First'),
    '60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54')

-- Scrubber: nothing raw may survive; ordinary text must be untouched.
SA.setTenantKey('test-key')
local function clean(name, input, mustNotContain)
    local out = SA.scrubString(input)
    for _, bad in ipairs(mustNotContain) do
        check(name .. ' (removes ' .. bad .. ')', not out:find(bad, 1, true), out)
    end
end
clean('license', 'Kicked: license:1a2b3c4d5e6f7a8b9c0d', { 'license:', '1a2b3c4d5e6f' })
clean('discord', 'discord:987654321098765', { '987654321098765' })
clean('ip identifier', 'ip:203.0.113.9 joined', { '203.0.113.9' })
clean('ip:port', 'connect 51.79.12.34:30120 now', { '51.79.12.34' })
clean('db uri', 'set x "mysql://root:pw@10.0.0.5/rp"', { 'root:pw', 'mysql://' })
clean('webhook', 'https://discord.com/api/webhooks/1234567890/AbC_dEf-123', { 'AbC_dEf-123' })
clean('bearer', 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345', { 'abcdefghijklmnop' })
clean('password=', 'Password=letmein123', { 'letmein123' })
clean('rcon', 'rcon_password "changeme123"', { 'changeme123' })
-- Fake token assembled at runtime so secret scanners don't mistake this file for a leak.
local fakeBotToken = 'M' .. string.rep('x', 23) .. '.' .. 'GhIjKl' .. '.' .. string.rep('y', 27)
clean('bot token', fakeBotToken, { 'GhIjKl' })
eq('plain text untouched', SA.scrubString('Kaiden_R bought a burger for $12'), 'Kaiden_R bought a burger for $12')
eq('provenance untouched', SA.scrubString('bsd_banking:deposit'), 'bsd_banking:deposit')
eq('same identifier, same pseudonym', SA.pseudonym('license:abc'), SA.pseudonym('license:abc'))
check('pseudonym is 32 hex', SA.pseudonym('license:abc'):match('^%x+$') and #SA.pseudonym('license:abc') == 32)

print(('%d passed, %d failed'):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
