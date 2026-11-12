--[[
PNG decoder (pure Lua) producing 8-bit grayscale.
Supports bit depths 1/2/4/8/16, all color types, palettes and transparency
(composited on white). Interlaced (Adam7) images are rejected.
--]]
local ffi = require("ffi")
local bit = require("bit")
local inflate = require("tome.inflate")

local M = {}

local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function paeth(a, b, c)
    local p = a + b - c
    local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
    if pa <= pb and pa <= pc then return a end
    if pb <= pc then return b end
    return c
end

--- Returns { w, h, buf = uint8_t[w*h] } or nil, err
function M.decode(data)
    if data:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil, "not a PNG" end
    local pos = 9
    local w, h, depth, ctype, interlace
    local idat = {}
    local palette, trns
    while pos + 8 <= #data do
        local len = be32(data, pos)
        local kind = data:sub(pos + 4, pos + 7)
        local body = data:sub(pos + 8, pos + 7 + len)
        if kind == "IHDR" then
            w, h = be32(body, 1), be32(body, 5)
            depth, ctype, interlace = body:byte(9), body:byte(10), body:byte(13)
        elseif kind == "PLTE" then
            palette = body
        elseif kind == "tRNS" then
            trns = body
        elseif kind == "IDAT" then
            idat[#idat + 1] = body
        elseif kind == "IEND" then
            break
        end
        pos = pos + 12 + len
    end
    if not w then return nil, "missing IHDR" end
    if interlace ~= 0 then return nil, "interlaced PNG not supported" end
    if w * h > 40e6 then return nil, "image too large" end
    local channels = ({ [0] = 1, [2] = 3, [3] = 1, [4] = 2, [6] = 4 })[ctype]
    if not channels then return nil, "bad color type" end
    local bpp_bits = channels * depth
    local bpp = math.max(1, bpp_bits / 8)          -- bytes per pixel for filtering
    local stride = math.ceil(w * bpp_bits / 8)
    local ok, raw = pcall(inflate.zlib_inflate, table.concat(idat), (stride + 1) * h)
    if not ok then return nil, raw end
    if #raw < (stride + 1) * h then return nil, "truncated image data" end
    local src = ffi.cast("const uint8_t*", raw)

    -- Unfilter in place into `cur`, keeping the previous row in `prev`.
    local prev = ffi.new("uint8_t[?]", stride)
    local cur = ffi.new("uint8_t[?]", stride)
    local out = ffi.new("uint8_t[?]", w * h)

    -- grayscale lookup for palette images
    local pal_gray
    if ctype == 3 then
        if not palette then return nil, "missing palette" end
        pal_gray = ffi.new("uint8_t[256]")
        for i = 0, math.floor(#palette / 3) - 1 do
            local r, g, b = palette:byte(i * 3 + 1, i * 3 + 3)
            local y = (r * 299 + g * 587 + b * 114) / 1000
            local a = trns and trns:byte(i + 1) or 255
            pal_gray[i] = math.floor((y * a + 255 * (255 - a)) / 255 + 0.5)
        end
    end
    local maxv = bit.lshift(1, depth) - 1

    for y = 0, h - 1 do
        local base = y * (stride + 1)
        local ft = src[base]
        local p = src + base + 1
        for x = 0, stride - 1 do
            local a = x >= bpp and cur[x - bpp] or 0
            local b = prev[x]
            local v = p[x]
            if ft == 1 then v = v + a
            elseif ft == 2 then v = v + b
            elseif ft == 3 then v = v + bit.rshift(a + b, 1)
            elseif ft == 4 then v = v + paeth(a, b, x >= bpp and prev[x - bpp] or 0) end
            cur[x] = bit.band(v, 255)
        end
        local row = y * w
        if depth == 8 or depth == 16 then
            local step = depth / 8
            for x = 0, w - 1 do
                local i = x * channels * step
                local g
                if ctype == 0 then
                    g = cur[i]
                elseif ctype == 2 or ctype == 6 then
                    g = (cur[i] * 299 + cur[i + step] * 587 + cur[i + 2 * step] * 114) / 1000
                elseif ctype == 4 then
                    g = cur[i]
                else -- 3
                    g = pal_gray[cur[i]]
                end
                if ctype == 4 or ctype == 6 then
                    local alpha = cur[i + (channels - 1) * step]
                    g = (g * alpha + 255 * (255 - alpha)) / 255
                end
                out[row + x] = math.floor(g + 0.5)
            end
        else
            -- sub-byte depths (gray or palette)
            local per = 8 / depth
            for x = 0, w - 1 do
                local byte = cur[math.floor(x / per)]
                local shift = 8 - depth * (x % per + 1)
                local v = bit.band(bit.rshift(byte, shift), maxv)
                if ctype == 3 then out[row + x] = pal_gray[v]
                else out[row + x] = math.floor(v * 255 / maxv) end
            end
        end
        prev, cur = cur, prev
    end
    return { w = w, h = h, buf = out }
end

return M
