--[[
8-bit grayscale drawing surface (0 = black, 255 = white). Everything is
drawn here, then the display backend pushes it to the screen.
--]]
local ffi = require("ffi")
local bit = require("bit")
local util = require("tome.util")

local Canvas = {}
Canvas.__index = Canvas

function Canvas.new(w, h)
    local self = setmetatable({ w = w, h = h }, Canvas)
    self.buf = ffi.new("uint8_t[?]", w * h)
    ffi.fill(self.buf, w * h, 255)
    return self
end

function Canvas:clear(v)
    ffi.fill(self.buf, self.w * self.h, v or 255)
end

function Canvas:fill_rect(x, y, w, h, v)
    x, y = math.floor(x), math.floor(y)
    local x0, y0 = math.max(0, x), math.max(0, y)
    local x1, y1 = math.min(self.w, x + w), math.min(self.h, y + h)
    if x1 <= x0 or y1 <= y0 then return end
    for yy = y0, y1 - 1 do
        ffi.fill(self.buf + yy * self.w + x0, x1 - x0, v)
    end
end

function Canvas:rect(x, y, w, h, v, t)
    t = t or 1
    self:fill_rect(x, y, w, t, v)
    self:fill_rect(x, y + h - t, w, t, v)
    self:fill_rect(x, y, t, h, v)
    self:fill_rect(x + w - t, y, t, h, v)
end

function Canvas:invert_rect(x, y, w, h)
    local x0, y0 = math.max(0, math.floor(x)), math.max(0, math.floor(y))
    local x1, y1 = math.min(self.w, math.floor(x + w)), math.min(self.h, math.floor(y + h))
    local buf = self.buf
    for yy = y0, y1 - 1 do
        local row = yy * self.w
        for xx = x0, x1 - 1 do buf[row + xx] = 255 - buf[row + xx] end
    end
end

--- Draw a UTF-8 string with its baseline at y. Returns the x after the text.
function Canvas:text(font, s, x, y, color)
    color = color or 0
    local buf, cw, ch = self.buf, self.w, self.h
    local blob = font.blob
    local pen = x
    y = math.floor(y + 0.5) -- fractional rows would offset the buffer index
    for _, cp in util.utf8_iter(s) do
        local g = font:glyph(cp)
        if g then
            local gx = math.floor(pen + 0.5) + g.left
            local gy = y - g.top
            local gw, gh, off = g.w, g.h, g.off
            for row = 0, gh - 1 do
                local py = gy + row
                if py >= 0 and py < ch then
                    local dst = py * cw
                    local src = off + row * gw
                    for col = 0, gw - 1 do
                        local px = gx + col
                        local a = blob[src + col]
                        if a > 0 and px >= 0 and px < cw then
                            local i = dst + px
                            -- alpha blend towards `color`
                            buf[i] = bit.rshift(buf[i] * (255 - a) + color * a, 8)
                        end
                    end
                end
            end
            pen = pen + g.adv
        end
    end
    return pen
end

-- CRC32 table for PNG chunks.
local crc_table = ffi.new("uint32_t[256]")
for n = 0, 255 do
    local c = n
    for _ = 1, 8 do
        if bit.band(c, 1) ~= 0 then c = bit.bxor(0xEDB88320, bit.rshift(c, 1)) else c = bit.rshift(c, 1) end
    end
    crc_table[n] = c
end

local function crc32(s, crc)
    crc = bit.bnot(crc or 0)
    local p = ffi.cast("const uint8_t*", s)
    for i = 0, #s - 1 do
        crc = bit.bxor(crc_table[bit.band(bit.bxor(crc, p[i]), 0xFF)], bit.rshift(crc, 8))
    end
    return bit.bnot(crc)
end

local function be32(n)
    n = n % 4294967296
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

local function chunk(kind, data)
    local c = crc32(kind .. data)
    return be32(#data) .. kind .. data .. be32(c < 0 and c + 4294967296 or c)
end

--- Encode a region as an 8-bit grayscale PNG using stored (uncompressed)
-- deflate blocks: fast on slow CPUs, and the file only lives in /tmp.
function Canvas:to_png(x, y, w, h)
    x, y, w, h = x or 0, y or 0, w or self.w, h or self.h
    local rowlen = w + 1
    local raw = ffi.new("uint8_t[?]", rowlen * h)
    for r = 0, h - 1 do
        raw[r * rowlen] = 0 -- filter: none
        ffi.copy(raw + r * rowlen + 1, self.buf + (y + r) * self.w + x, w)
    end
    local total = rowlen * h
    local parts = { "\120\1" } -- zlib header, no compression
    local a, b = 1, 0
    for i = 0, total - 1 do
        a = (a + raw[i]) % 65521
        b = (b + a) % 65521
    end
    local pos = 0
    while pos < total do
        local n = math.min(65535, total - pos)
        local final = (pos + n >= total) and 1 or 0
        parts[#parts + 1] = string.char(final, n % 256, math.floor(n / 256), (65535 - n) % 256, math.floor((65535 - n) / 256))
        parts[#parts + 1] = ffi.string(raw + pos, n)
        pos = pos + n
    end
    parts[#parts + 1] = be32(b * 65536 + a)
    local idat = table.concat(parts)
    local ihdr = be32(w) .. be32(h) .. "\8\0\0\0\0" -- 8-bit grayscale
    return "\137PNG\r\n\26\n" .. chunk("IHDR", ihdr) .. chunk("IDAT", idat) .. chunk("IEND", "")
end

return Canvas
