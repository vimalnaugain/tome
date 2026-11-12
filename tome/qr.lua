--[[
QR code encoder (ISO/IEC 18004), enough for short URLs: byte mode, error
correction level M, versions 1-6 (up to 106 bytes). Pure Lua.

qr.encode(text) -> matrix: matrix.size, matrix[y][x] = true for dark modules
qr.draw(canvas, matrix, x, y, size) draws it with a 4-module quiet zone.
--]]
local bit = require("bit")
local band, bxor, lshift, rshift = bit.band, bit.bxor, bit.lshift, bit.rshift

local qr = {}

-- Version -> { data codewords per block (list), ec codewords per block }, level M
local BLOCKS = {
    { { 16 }, 10 },
    { { 28 }, 16 },
    { { 44 }, 26 },
    { { 32, 32 }, 18 },
    { { 43, 43 }, 24 },
    { { 27, 27, 27, 27 }, 16 },
}
local ALIGN = { {}, { 6, 18 }, { 6, 22 }, { 6, 26 }, { 6, 30 }, { 6, 34 } }

-- GF(256) with polynomial 0x11D
local EXP, LOG = {}, {}
do
    local x = 1
    for i = 0, 254 do
        EXP[i] = x
        LOG[x] = i
        x = x * 2
        if x >= 256 then x = bxor(x, 0x11D) end
    end
    for i = 255, 511 do EXP[i] = EXP[i - 255] end
end
local function gmul(a, b)
    if a == 0 or b == 0 then return 0 end
    return EXP[LOG[a] + LOG[b]]
end

local function generator(n)
    local g = { 1 }
    for i = 0, n - 1 do
        local ng = {}
        for j = 1, #g + 1 do ng[j] = 0 end
        for j = 1, #g do
            ng[j] = bxor(ng[j], g[j])                  -- * x
            ng[j + 1] = bxor(ng[j + 1], gmul(g[j], EXP[i])) -- * alpha^i
        end
        g = ng
    end
    return g -- highest degree first, g[1] == 1
end

local function rs_ec(data, n)
    local g = generator(n)
    local rem = {}
    for i = 1, n do rem[i] = 0 end
    for _, d in ipairs(data) do
        local factor = bxor(d, rem[1])
        table.remove(rem, 1)
        rem[n] = 0
        for i = 1, n do rem[i] = bxor(rem[i], gmul(g[i + 1], factor)) end
    end
    return rem
end

--- Data codewords for `text` in byte mode at `version`.
local function codewords(text, version)
    local spec = BLOCKS[version]
    local total = 0
    for _, n in ipairs(spec[1]) do total = total + n end
    local bits = {}
    local function put(v, n) for i = n - 1, 0, -1 do bits[#bits + 1] = band(rshift(v, i), 1) end end
    put(4, 4)           -- byte mode
    put(#text, 8)       -- character count (versions 1-9)
    for i = 1, #text do put(text:byte(i), 8) end
    local cap = total * 8
    for _ = 1, math.min(4, cap - #bits) do bits[#bits + 1] = 0 end -- terminator
    while #bits % 8 ~= 0 do bits[#bits + 1] = 0 end
    local out = {}
    for i = 1, #bits, 8 do
        local v = 0
        for j = 0, 7 do v = v * 2 + bits[i + j] end
        out[#out + 1] = v
    end
    local pad = { 0xEC, 0x11 }
    local k = 1
    while #out < total do out[#out + 1] = pad[k]; k = 3 - k end
    return out
end

local function interleave(data, version)
    local spec = BLOCKS[version]
    local blocks, ecs = {}, {}
    local pos = 1
    for b, n in ipairs(spec[1]) do
        local blk = {}
        for i = 0, n - 1 do blk[#blk + 1] = data[pos + i] end
        pos = pos + n
        blocks[b] = blk
        ecs[b] = rs_ec(blk, spec[2])
    end
    local out = {}
    local maxn = 0
    for _, b in ipairs(blocks) do maxn = math.max(maxn, #b) end
    for i = 1, maxn do
        for _, b in ipairs(blocks) do if b[i] then out[#out + 1] = b[i] end end
    end
    for i = 1, spec[2] do
        for _, e in ipairs(ecs) do out[#out + 1] = e[i] end
    end
    return out
end

local MASKS = {
    [0] = function(r, c) return (r + c) % 2 == 0 end,
    function(r) return r % 2 == 0 end,
    function(_, c) return c % 3 == 0 end,
    function(r, c) return (r + c) % 3 == 0 end,
    function(r, c) return (math.floor(r / 2) + math.floor(c / 3)) % 2 == 0 end,
    function(r, c) return (r * c) % 2 + (r * c) % 3 == 0 end,
    function(r, c) return ((r * c) % 2 + (r * c) % 3) % 2 == 0 end,
    function(r, c) return ((r + c) % 2 + (r * c) % 3) % 2 == 0 end,
}

local function format_bits(mask)
    local data = lshift(0, 3) + mask -- level M = 00
    local v = lshift(data, 10)
    for i = 14, 10, -1 do
        if band(rshift(v, i), 1) == 1 then v = bxor(v, lshift(0x537, i - 10)) end
    end
    return bxor(lshift(data, 10) + v, 0x5412)
end

--- Build the matrix for a version and mask from the final codewords.
local function build(version, words, mask)
    local n = 17 + 4 * version
    local m, fn = {}, {} -- modules, function-pattern flags
    for y = 0, n - 1 do m[y], fn[y] = {}, {} end
    local function set(x, y, dark) m[y][x] = dark; fn[y][x] = true end

    local function finder(cx, cy)
        for dy = -4, 4 do
            for dx = -4, 4 do
                local x, y = cx + dx, cy + dy
                if x >= 0 and x < n and y >= 0 and y < n then
                    local d = math.max(math.abs(dx), math.abs(dy))
                    set(x, y, d ~= 2 and d ~= 4)
                end
            end
        end
    end
    finder(3, 3); finder(n - 4, 3); finder(3, n - 4)
    for i = 8, n - 9 do set(i, 6, i % 2 == 0); set(6, i, i % 2 == 0) end
    local al = ALIGN[version]
    for _, ay in ipairs(al) do
        for _, ax in ipairs(al) do
            if not fn[ay][ax] then
                for dy = -2, 2 do
                    for dx = -2, 2 do
                        set(ax + dx, ay + dy, math.max(math.abs(dx), math.abs(dy)) ~= 1)
                    end
                end
            end
        end
    end
    -- format areas (filled below) and the dark module
    local f = format_bits(mask)
    local function fbit(i) return band(rshift(f, i), 1) == 1 end
    for i = 0, 5 do set(8, i, fbit(i)) end
    set(8, 7, fbit(6)); set(8, 8, fbit(7)); set(7, 8, fbit(8))
    for i = 9, 14 do set(14 - i, 8, fbit(i)) end
    for i = 0, 7 do set(n - 1 - i, 8, fbit(i)) end
    for i = 8, 14 do set(8, n - 15 + i, fbit(i)) end
    set(8, n - 8, true)

    -- data, zigzag from the bottom right
    local bits = {}
    for _, w in ipairs(words) do for i = 7, 0, -1 do bits[#bits + 1] = band(rshift(w, i), 1) == 1 end end
    local k = 1
    local maskf = MASKS[mask]
    local x = n - 1
    local upward = true
    while x > 0 do
        if x == 6 then x = x - 1 end
        for i = 0, n - 1 do
            local y = upward and (n - 1 - i) or i
            for dx = 0, 1 do
                local xx = x - dx
                if not fn[y][xx] then
                    local b = bits[k] or false
                    k = k + 1
                    if maskf(y, xx) then b = not b end
                    m[y][xx] = b
                end
            end
        end
        upward = not upward
        x = x - 2
    end
    m.size = n
    return m
end

--- Penalty score (lower is better) per the standard's four rules.
local function penalty(m)
    local n = m.size
    local score = 0
    for pass = 1, 2 do
        for a = 0, n - 1 do
            local run, last = 0, nil
            for b = 0, n - 1 do
                local v = pass == 1 and m[a][b] or m[b][a]
                if v == last then
                    run = run + 1
                else
                    if run >= 5 then score = score + run - 2 end
                    run, last = 1, v
                end
            end
            if run >= 5 then score = score + run - 2 end
        end
    end
    for y = 0, n - 2 do
        for x = 0, n - 2 do
            local v = m[y][x]
            if m[y][x + 1] == v and m[y + 1][x] == v and m[y + 1][x + 1] == v then score = score + 3 end
        end
    end
    local pat1 = { true, false, true, true, true, false, true, false, false, false, false }
    local pat2 = { false, false, false, false, true, false, true, true, true, false, true }
    for a = 0, n - 1 do
        for b = 0, n - 11 do
            for _, pat in ipairs({ pat1, pat2 }) do
                local h, v = true, true
                for i = 1, 11 do
                    if m[a][b + i - 1] ~= pat[i] then h = false end
                    if m[b + i - 1][a] ~= pat[i] then v = false end
                end
                if h then score = score + 40 end
                if v then score = score + 40 end
            end
        end
    end
    local dark = 0
    for y = 0, n - 1 do for x = 0, n - 1 do if m[y][x] then dark = dark + 1 end end end
    local pct = dark * 100 / (n * n)
    score = score + math.floor(math.abs(pct - 50) / 5) * 10
    return score
end

--- Encode text. Optional version/mask force a choice (used by tests).
function qr.encode(text, version, mask)
    if not version then
        for v = 1, #BLOCKS do
            local total = 0
            for _, nb in ipairs(BLOCKS[v][1]) do total = total + nb end
            if #text + 2 <= total then version = v; break end
        end
    end
    if not version then error("text too long for a QR code (max 106 bytes)") end
    local words = interleave(codewords(text, version), version)
    if mask then return build(version, words, mask) end
    local best, best_score
    for mk = 0, 7 do
        local m = build(version, words, mk)
        local s = penalty(m)
        if not best_score or s < best_score then best, best_score = m, s end
    end
    return best
end

--- Draw with a 4-module white quiet zone, fitting `size` pixels.
function qr.draw(canvas, m, x, y, size)
    local n = m.size
    local scale = math.max(1, math.floor(size / (n + 8)))
    local total = scale * (n + 8)
    canvas:fill_rect(x, y, total, total, 255)
    local ox, oy = x + 4 * scale, y + 4 * scale
    for yy = 0, n - 1 do
        for xx = 0, n - 1 do
            if m[yy][xx] then canvas:fill_rect(ox + xx * scale, oy + yy * scale, scale, scale, 0) end
        end
    end
    return total
end

return qr
