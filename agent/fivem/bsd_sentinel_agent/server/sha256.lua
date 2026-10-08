-- =============================================================================
-- bsd_sentinel_agent / server / sha256.lua
-- SHA-256 and HMAC-SHA256 in plain Lua 5.4 (FXServer has no hashing natives).
-- Used for player pseudonyms: raw licenses never leave the game server.
-- Verified against the FIPS 180-2 and RFC 4231 test vectors (agent/fivem/test).
-- =============================================================================

SA = SA or {}

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local M32 = 0xffffffff

local function rrot(x, n)
    return ((x >> n) | (x << (32 - n))) & M32
end

--- Raw 32-byte SHA-256 digest of a byte string.
local function sha256Raw(msg)
    local h0, h1, h2, h3 = 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a
    local h4, h5, h6, h7 = 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19

    local bitLen = #msg * 8
    msg = msg .. '\128' .. string.rep('\0', (55 - #msg) % 64) .. string.pack('>I8', bitLen)

    local w = {}
    for chunk = 1, #msg, 64 do
        for i = 0, 15 do
            w[i] = string.unpack('>I4', msg, chunk + i * 4)
        end
        for i = 16, 63 do
            local x, y = w[i - 15], w[i - 2]
            local s0 = rrot(x, 7) ~ rrot(x, 18) ~ (x >> 3)
            local s1 = rrot(y, 17) ~ rrot(y, 19) ~ (y >> 10)
            w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & M32
        end

        local a, b, c, d, e, f, g, h = h0, h1, h2, h3, h4, h5, h6, h7
        for i = 0, 63 do
            local S1 = rrot(e, 6) ~ rrot(e, 11) ~ rrot(e, 25)
            local ch = (e & f) ~ ((~e & M32) & g)
            local t1 = (h + S1 + ch + K[i + 1] + w[i]) & M32
            local S0 = rrot(a, 2) ~ rrot(a, 13) ~ rrot(a, 22)
            local maj = (a & b) ~ (a & c) ~ (b & c)
            local t2 = (S0 + maj) & M32
            h, g, f, e = g, f, e, (d + t1) & M32
            d, c, b, a = c, b, a, (t1 + t2) & M32
        end

        h0 = (h0 + a) & M32; h1 = (h1 + b) & M32; h2 = (h2 + c) & M32; h3 = (h3 + d) & M32
        h4 = (h4 + e) & M32; h5 = (h5 + f) & M32; h6 = (h6 + g) & M32; h7 = (h7 + h) & M32
    end

    return string.pack('>I4I4I4I4I4I4I4I4', h0, h1, h2, h3, h4, h5, h6, h7)
end

local function toHex(bytes)
    return (bytes:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

local function fromHex(hex)
    return (hex:gsub('%x%x', function(pair) return string.char(tonumber(pair, 16)) end))
end

--- Raw 32-byte HMAC-SHA256.
local function hmacRaw(key, msg)
    if #key > 64 then key = sha256Raw(key) end
    key = key .. string.rep('\0', 64 - #key)
    local ipad = key:gsub('.', function(c) return string.char(c:byte() ~ 0x36) end)
    local opad = key:gsub('.', function(c) return string.char(c:byte() ~ 0x5c) end)
    return sha256Raw(opad .. sha256Raw(ipad .. msg))
end

SA.sha256Raw = sha256Raw
SA.toHex = toHex
SA.fromHex = fromHex
SA.sha256Hex = function(msg) return toHex(sha256Raw(msg)) end
SA.hmacHex = function(key, msg) return toHex(hmacRaw(key, msg)) end
