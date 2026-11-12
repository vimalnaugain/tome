--[[
Pure-Lua DEFLATE decoder (RFC 1951), used for EPUB (zip) entries and font
packs. Only LuaJIT's `bit` and `ffi` data types are used -- no C calls -- so
it works in the statically linked Kindle binary.
--]]
local bit = require("bit")
local ffi = require("ffi")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local M = {}

local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

-- Canonical Huffman table: counts[len], symbols sorted by code.
local function build(lengths, n)
    local counts, offs, symbols = {}, {}, {}
    for i = 0, 15 do counts[i] = 0 end
    for s = 0, n - 1 do counts[lengths[s] or 0] = counts[lengths[s] or 0] + 1 end
    counts[0] = 0
    offs[1] = 0
    for i = 1, 14 do offs[i + 1] = offs[i] + counts[i] end
    for s = 0, n - 1 do
        local l = lengths[s] or 0
        if l ~= 0 then
            symbols[offs[l]] = s
            offs[l] = offs[l] + 1
        end
    end
    return { counts = counts, symbols = symbols }
end

local FIXED_LIT, FIXED_DIST
do
    local l = {}
    for i = 0, 143 do l[i] = 8 end
    for i = 144, 255 do l[i] = 9 end
    for i = 256, 279 do l[i] = 7 end
    for i = 280, 287 do l[i] = 8 end
    FIXED_LIT = build(l, 288)
    local d = {}
    for i = 0, 29 do d[i] = 5 end
    FIXED_DIST = build(d, 30)
end

--- Inflate a raw deflate stream. Returns the decompressed string.
-- @param data compressed string
-- @param size_hint expected output size (optional)
function M.inflate(data, size_hint)
    local src = ffi.cast("const uint8_t*", data)
    local srclen = #data
    local pos = 0 -- byte index into src
    local bitbuf, bitcnt = 0, 0

    local cap = math.max(size_hint or 0, srclen * 4, 1024)
    local out = ffi.new("uint8_t[?]", cap)
    local olen = 0

    local function ensure(n)
        if olen + n > cap then
            while olen + n > cap do cap = cap * 2 end
            local nb = ffi.new("uint8_t[?]", cap)
            ffi.copy(nb, out, olen)
            out = nb
        end
    end

    local function bits(need)
        while bitcnt < need do
            if pos >= srclen then error("inflate: unexpected end of data") end
            bitbuf = bor(bitbuf, lshift(src[pos], bitcnt))
            pos = pos + 1
            bitcnt = bitcnt + 8
        end
        local v = band(bitbuf, lshift(1, need) - 1)
        bitbuf = rshift(bitbuf, need)
        bitcnt = bitcnt - need
        return v
    end

    local function decode(h)
        local code, first, index = 0, 0, 0
        local counts = h.counts
        for len = 1, 15 do
            code = bor(code, bits(1))
            local count = counts[len]
            if code - count < first then
                return h.symbols[index + (code - first)]
            end
            index = index + count
            first = lshift(first + count, 1)
            code = lshift(code, 1)
        end
        error("inflate: bad huffman code")
    end

    local function codes(lit, dist)
        while true do
            local sym = decode(lit)
            if sym < 256 then
                if olen >= cap then ensure(1) end
                out[olen] = sym
                olen = olen + 1
            elseif sym == 256 then
                return
            else
                sym = sym - 257
                if sym >= 29 then error("inflate: bad length symbol") end
                local len = LEN_BASE[sym + 1] + bits(LEN_EXTRA[sym + 1])
                local ds = decode(dist)
                if ds >= 30 then error("inflate: bad distance symbol") end
                local d = DIST_BASE[ds + 1] + bits(DIST_EXTRA[ds + 1])
                if d > olen then error("inflate: distance too far back") end
                ensure(len)
                local from = olen - d
                for i = 0, len - 1 do out[olen + i] = out[from + i] end
                olen = olen + len
            end
        end
    end

    local final = 0
    repeat
        final = bits(1)
        local btype = bits(2)
        if btype == 0 then
            bitbuf, bitcnt = 0, 0
            if pos + 4 > srclen then error("inflate: truncated stored block") end
            local len = src[pos] + src[pos + 1] * 256
            pos = pos + 4
            if pos + len > srclen then error("inflate: truncated stored block") end
            ensure(len)
            ffi.copy(out + olen, src + pos, len)
            olen = olen + len
            pos = pos + len
        elseif btype == 1 then
            codes(FIXED_LIT, FIXED_DIST)
        elseif btype == 2 then
            local nlen = bits(5) + 257
            local ndist = bits(5) + 1
            local ncode = bits(4) + 4
            local cl = {}
            for i = 0, 18 do cl[i] = 0 end
            for i = 1, ncode do cl[CL_ORDER[i]] = bits(3) end
            local clh = build(cl, 19)
            local lengths = {}
            local i = 0
            while i < nlen + ndist do
                local sym = decode(clh)
                if sym < 16 then
                    lengths[i] = sym
                    i = i + 1
                else
                    local rep, val = 0, 0
                    if sym == 16 then
                        if i == 0 then error("inflate: repeat with no previous length") end
                        val = lengths[i - 1]
                        rep = 3 + bits(2)
                    elseif sym == 17 then
                        rep = 3 + bits(3)
                    else
                        rep = 11 + bits(7)
                    end
                    for _ = 1, rep do
                        lengths[i] = val
                        i = i + 1
                    end
                end
            end
            local litl, distl = {}, {}
            for k = 0, nlen - 1 do litl[k] = lengths[k] end
            for k = 0, ndist - 1 do distl[k] = lengths[nlen + k] end
            codes(build(litl, nlen), build(distl, ndist))
        else
            error("inflate: invalid block type")
        end
    until final == 1

    return ffi.string(out, olen)
end

--- Inflate a zlib-wrapped stream (2-byte header, adler32 trailer ignored).
function M.zlib_inflate(data, size_hint)
    return M.inflate(data:sub(3), size_hint)
end

return M
