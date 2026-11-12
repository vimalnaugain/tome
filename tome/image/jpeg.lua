--[[
JPEG decoder (pure Lua), baseline and progressive, producing 8-bit grayscale.

Only the luminance (Y) channel is reconstructed: an e-ink screen is gray, so
color channels are Huffman-decoded where needed to stay in sync, but never
transformed. Arithmetic-coded and lossless JPEGs are rejected.
--]]
local ffi = require("ffi")
local bit = require("bit")
local band, bor, lshift, rshift = bit.band, bit.bor, bit.lshift, bit.rshift

local M = {}

local ZIGZAG = ffi.new("int[64]", { 0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48,
    41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37,
    44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63 })

-- COS[x*8+u] = c(u) * cos((2x+1) u pi / 16) / 2
local COS = ffi.new("double[64]")
for x = 0, 7 do
    for u = 0, 7 do
        COS[x * 8 + u] = (u == 0 and 1 / math.sqrt(2) or 1) * math.cos((2 * x + 1) * u * math.pi / 16) / 2
    end
end

local function u16(s, i) local a, b = s:byte(i, i + 1); return a * 256 + b end

local function build_huffman(counts, symbols)
    local h = { maxcode = {}, valptr = {}, mincode = {}, symbols = symbols }
    local code, k = 0, 0
    for l = 1, 16 do
        local n = counts[l]
        if n > 0 then
            h.valptr[l], h.mincode[l] = k, code
            code, k = code + n, k + n
            h.maxcode[l] = code - 1
        else
            h.maxcode[l] = -1
        end
        code = code * 2
    end
    return h
end

--- Entropy-coded segment reader starting at 1-based string index `start`.
local function new_reader(data, start)
    local src = ffi.cast("const uint8_t*", data)
    local n = #data
    local r = { p = start - 1, bitbuf = 0, bitcnt = 0, marker = false }
    local function fill()
        while r.bitcnt <= 24 do
            local byte = 0
            if not r.marker and r.p < n then
                byte = src[r.p]
                if byte == 0xFF then
                    if src[r.p + 1] == 0 then r.p = r.p + 2 else r.marker = true; byte = 0 end
                else
                    r.p = r.p + 1
                end
            end
            r.bitbuf = bor(lshift(r.bitbuf, 8), byte)
            r.bitcnt = r.bitcnt + 8
        end
    end
    function r.bits(k)
        if k == 0 then return 0 end
        if r.bitcnt < k then fill() end
        local v = band(rshift(r.bitbuf, r.bitcnt - k), lshift(1, k) - 1)
        r.bitcnt = r.bitcnt - k
        return v
    end
    function r.huff(h)
        local code = 0
        for l = 1, 16 do
            code = code * 2 + r.bits(1)
            if code <= h.maxcode[l] then return h.symbols[h.valptr[l] + code - h.mincode[l] + 1] end
        end
        error("bad huffman code")
    end
    --- Skip the next RSTn marker and reset the bit buffer.
    function r.restart()
        r.bitbuf, r.bitcnt, r.marker = 0, 0, false
        while r.p < n - 1 and not (src[r.p] == 0xFF and src[r.p + 1] >= 0xD0 and src[r.p + 1] <= 0xD7) do r.p = r.p + 1 end
        r.p = r.p + 2
    end
    return r
end

local function extend(v, t)
    if t == 0 then return 0 end
    if v < lshift(1, t - 1) then return v - lshift(1, t) + 1 end
    return v
end

--- 1-based index of the next marker (not stuffing, not RSTn) at/after `from`.
local function scan_end(data, from)
    local i = from
    while true do
        i = data:find("\255", i, true)
        if not i then return #data + 1 end
        local nb = data:byte(i + 1)
        if nb and nb ~= 0 and not (nb >= 0xD0 and nb <= 0xD7) and nb ~= 0xFF then return i end
        i = i + 1
    end
end

--- Dequantize + IDCT one block of Y into the output plane.
local function idct_block(coef, q, plane, stride, ox, oy, tmp, f)
    for k = 0, 63 do f[ZIGZAG[k]] = coef[ZIGZAG[k]] * q[k] end
    for y = 0, 7 do
        for u = 0, 7 do
            local s = 0
            for v = 0, 7 do s = s + COS[y * 8 + v] * f[v * 8 + u] end
            tmp[y * 8 + u] = s
        end
    end
    for y = 0, 7 do
        local row = (oy + y) * stride + ox
        for x = 0, 7 do
            local s = 0
            for u = 0, 7 do s = s + COS[x * 8 + u] * tmp[y * 8 + u] end
            local v = math.floor(s + 128.5)
            plane[row + x] = v < 0 and 0 or (v > 255 and 255 or v)
        end
    end
end

function M.decode(data)
    if data:sub(1, 2) ~= "\255\216" then return nil, "not a JPEG" end
    local pos, n = 3, #data
    local qt, hts = {}, { [0] = {}, [1] = {} }
    local frame, restart_interval = nil, 0
    local coefs, bw, bh -- Y coefficients: bw x bh blocks of 64 int32

    local function setup_frame()
        local f = frame
        f.hmax, f.vmax = 1, 1
        for _, c in ipairs(f.comps) do f.hmax = math.max(f.hmax, c.h); f.vmax = math.max(f.vmax, c.v) end
        f.mcux = math.ceil(f.w / (8 * f.hmax))
        f.mcuy = math.ceil(f.h / (8 * f.vmax))
        f.Y = f.comps[1]
        bw, bh = f.mcux * f.Y.h, f.mcuy * f.Y.v
        coefs = ffi.new("int32_t[?]", bw * bh * 64)
    end

    --- Decode one scan. For every block of every component in the scan,
    -- `fn(reader, comp, block_ptr_or_nil)` is called in bitstream order.
    local function run_scan(comps, start, fn)
        local f = frame
        local r = new_reader(data, start)
        local done = 0
        local function maybe_restart()
            if restart_interval > 0 and done > 0 and done % restart_interval == 0 then
                r.restart()
                for _, c in ipairs(comps) do c.pred = 0 end
                f.eobrun = 0
            end
        end
        for _, c in ipairs(comps) do c.pred = 0 end
        f.eobrun = 0
        local function blk(c, bx, by)
            if c == f.Y and bx < bw and by < bh then return coefs + (by * bw + bx) * 64 end
            return nil
        end
        if #comps == 1 then
            local c = comps[1]
            local cbw = math.ceil(math.ceil(f.w * c.h / f.hmax) / 8)
            local cbh = math.ceil(math.ceil(f.h * c.v / f.vmax) / 8)
            for by = 0, cbh - 1 do
                for bx = 0, cbw - 1 do
                    maybe_restart()
                    fn(r, c, blk(c, bx, by))
                    done = done + 1
                end
            end
        else
            for my = 0, f.mcuy - 1 do
                for mx = 0, f.mcux - 1 do
                    maybe_restart()
                    for _, c in ipairs(comps) do
                        for v = 0, c.v - 1 do
                            for h = 0, c.h - 1 do fn(r, c, blk(c, mx * c.h + h, my * c.v + v)) end
                        end
                    end
                    done = done + 1
                end
            end
        end
    end

    -- Baseline: DC + all AC in one pass.
    local function baseline_block(r, c, b)
        local t = r.huff(hts[0][c.td])
        c.pred = c.pred + extend(r.bits(t), t)
        if b then b[0] = c.pred end
        local ac = hts[1][c.ta]
        local k = 1
        while k < 64 do
            local rs = r.huff(ac)
            local run, s = rshift(rs, 4), band(rs, 15)
            if s == 0 then
                if run == 15 then k = k + 16 else break end
            else
                k = k + run
                local v = extend(r.bits(s), s)
                if b and k < 64 then b[ZIGZAG[k]] = v end
                k = k + 1
            end
        end
    end

    -- Progressive passes (ITU T.81 Annex G).
    local function progressive_scan(comps, start, ss, se, ah, al)
        local f = frame
        local p1, m1 = lshift(1, al), lshift(-1, al)
        if ss == 0 then
            if ah == 0 then
                run_scan(comps, start, function(r, c, b)
                    local t = r.huff(hts[0][c.td])
                    c.pred = c.pred + extend(r.bits(t), t)
                    if b then b[0] = c.pred * p1 end
                end)
            else
                run_scan(comps, start, function(r, _, b)
                    if r.bits(1) == 1 and b then b[0] = bor(b[0], p1) end
                end)
            end
            return
        end
        if ah == 0 then
            run_scan(comps, start, function(r, c, b)
                if f.eobrun > 0 then f.eobrun = f.eobrun - 1; return end
                local ac = hts[1][c.ta]
                local k = ss
                while k <= se do
                    local rs = r.huff(ac)
                    local run, s = rshift(rs, 4), band(rs, 15)
                    if s == 0 then
                        if run < 15 then
                            f.eobrun = lshift(1, run) - 1
                            if run > 0 then f.eobrun = f.eobrun + r.bits(run) end
                            break
                        end
                        k = k + 16
                    else
                        k = k + run
                        if b and k <= 63 then b[ZIGZAG[k]] = extend(r.bits(s), s) * p1 else r.bits(s) end
                        k = k + 1
                    end
                end
            end)
            return
        end
        -- AC refinement
        local dummy = ffi.new("int32_t[64]")
        run_scan(comps, start, function(r, c, b)
            b = b or dummy
            local k = ss
            local function refine(z)
                if b[z] ~= 0 and r.bits(1) == 1 and band(b[z], p1) == 0 then
                    if b[z] >= 0 then b[z] = b[z] + p1 else b[z] = b[z] + m1 end
                end
            end
            if f.eobrun <= 0 then
                local ac = hts[1][c.ta]
                while k <= se do
                    local rs = r.huff(ac)
                    local run, s = rshift(rs, 4), band(rs, 15)
                    local v = 0
                    if s == 0 then
                        if run < 15 then
                            f.eobrun = lshift(1, run)
                            if run > 0 then f.eobrun = f.eobrun + r.bits(run) end
                            break
                        end
                        -- run == 15: skip 16 zero coefficients (ZRL)
                    else
                        v = r.bits(1) == 1 and p1 or m1
                    end
                    while k <= se do
                        local z = ZIGZAG[k]
                        if b[z] ~= 0 then
                            refine(z)
                        else
                            if run == 0 then
                                if v ~= 0 then b[z] = v end
                                k = k + 1
                                break
                            end
                            run = run - 1
                        end
                        k = k + 1
                    end
                end
            end
            if f.eobrun > 0 then
                while k <= se do refine(ZIGZAG[k]); k = k + 1 end
                f.eobrun = f.eobrun - 1
            end
        end)
    end

    local function finish()
        local f = frame
        local Y = f.Y
        local stride = bw * 8
        local plane = ffi.new("uint8_t[?]", stride * bh * 8)
        local q = qt[Y.tq] or error("missing quantization table")
        local tmp, tf = ffi.new("double[64]"), ffi.new("double[64]")
        for by = 0, bh - 1 do
            for bx = 0, bw - 1 do
                idct_block(coefs + (by * bw + bx) * 64, q, plane, stride, bx * 8, by * 8, tmp, tf)
            end
        end
        local out_w = math.ceil(f.w * Y.h / f.hmax)
        local out_h = math.ceil(f.h * Y.v / f.vmax)
        local out = ffi.new("uint8_t[?]", out_w * out_h)
        for y = 0, out_h - 1 do ffi.copy(out + y * out_w, plane + y * stride, out_w) end
        return { w = out_w, h = out_h, buf = out }
    end

    local ok, res = pcall(function()
        while pos < n do
            if data:byte(pos) ~= 0xFF then error("bad marker at byte " .. pos) end
            local marker = data:byte(pos + 1)
            if marker == 0xFF then
                pos = pos + 1
            elseif marker == 0xD8 or (marker >= 0xD0 and marker <= 0xD7) or marker == 0x01 then
                pos = pos + 2
            elseif marker == 0xD9 then
                break
            else
                local len = u16(data, pos + 2)
                local seg = data:sub(pos + 4, pos + 1 + len)
                local next_pos = pos + 2 + len
                if marker == 0xDB then
                    local i = 1
                    while i <= #seg do
                        local pq, tq = rshift(seg:byte(i), 4), band(seg:byte(i), 15)
                        local q = ffi.new("double[64]")
                        for k = 0, 63 do q[k] = pq == 0 and seg:byte(i + 1 + k) or u16(seg, i + 1 + 2 * k) end
                        qt[tq] = q
                        i = i + 1 + 64 * (pq == 0 and 1 or 2)
                    end
                elseif marker == 0xC4 then
                    local i = 1
                    while i <= #seg do
                        local tc, th = rshift(seg:byte(i), 4), band(seg:byte(i), 15)
                        local counts, total = {}, 0
                        for l = 1, 16 do counts[l] = seg:byte(i + l); total = total + counts[l] end
                        hts[tc][th] = build_huffman(counts, { seg:byte(i + 17, i + 16 + total) })
                        i = i + 17 + total
                    end
                elseif marker == 0xC0 or marker == 0xC1 or marker == 0xC2 then
                    frame = { h = u16(seg, 2), w = u16(seg, 4), comps = {}, progressive = marker == 0xC2 }
                    for c = 0, seg:byte(6) - 1 do
                        local b = 7 + c * 3
                        local hv = seg:byte(b + 1)
                        frame.comps[#frame.comps + 1] = { id = seg:byte(b), h = rshift(hv, 4), v = band(hv, 15), tq = seg:byte(b + 2) }
                    end
                    if frame.w * frame.h > 40e6 then error("image too large") end
                    setup_frame()
                elseif marker >= 0xC3 and marker <= 0xCF and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                    error("unsupported JPEG type (arithmetic or lossless)")
                elseif marker == 0xDD then
                    restart_interval = u16(seg, 1)
                elseif marker == 0xDA then
                    if not frame then error("scan before frame") end
                    local ns = seg:byte(1)
                    local comps = {}
                    for i = 0, ns - 1 do
                        local cid, t = seg:byte(2 + i * 2), seg:byte(3 + i * 2)
                        for _, c in ipairs(frame.comps) do
                            if c.id == cid then c.td, c.ta = rshift(t, 4), band(t, 15); comps[#comps + 1] = c end
                        end
                    end
                    local ss, se = seg:byte(2 + ns * 2), seg:byte(3 + ns * 2)
                    local ahal = seg:byte(4 + ns * 2)
                    local has_y = false
                    for _, c in ipairs(comps) do if c == frame.Y then has_y = true end end
                    if not frame.progressive then
                        if has_y then
                            run_scan(comps, next_pos, baseline_block)
                            return finish()
                        end
                    elseif has_y then
                        progressive_scan(comps, next_pos, ss, se, rshift(ahal, 4), band(ahal, 15))
                    end
                    -- continue after this scan's entropy-coded data
                    next_pos = scan_end(data, next_pos)
                end
                pos = next_pos
            end
        end
        if frame and frame.progressive then return finish() end
        error("no image data")
    end)
    if not ok then return nil, tostring(res):gsub("^.-:%d+: ", "") end
    return res
end

return M
