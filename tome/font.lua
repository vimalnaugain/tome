--[[
Bitmap font packs (.tfnt, see tools/bake_fonts.py). Fonts are addressed by
face ("serif" | "sans"), style ("r" | "i" | "b" | "bi") and a requested pixel
size; the closest baked size is used.
--]]
local ffi = require("ffi")
local inflate = require("tome.inflate")
local util = require("tome.util")

local Font = {}
Font.__index = Font

local STYLE_NAME = { r = "regular", i = "italic", b = "bold", bi = "bolditalic" }
local loaded = {}
local font_dir = "fonts"

function Font.set_dir(dir) font_dir = dir end

local function rd(s, i, fmt)
    local b = { s:byte(i, i + 3) }
    if fmt == "u16" then return b[1] + b[2] * 256 end
    if fmt == "i16" then local v = b[1] + b[2] * 256; return v >= 32768 and v - 65536 or v end
    if fmt == "u32" then return b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216 end
    if fmt == "i32" then local v = b[1] + b[2] * 256 + b[3] * 65536 + b[4] * 16777216; return v >= 2147483648 and v - 4294967296 or v end
end

local function available_sizes(face_style)
    local sizes = {}
    for _, e in ipairs(util.list_dir(font_dir)) do
        local fs, sz = e.name:match("^(.+)%-(%d+)%.tfnt$")
        if fs == face_style then sizes[#sizes + 1] = tonumber(sz) end
    end
    table.sort(sizes)
    return sizes
end

local sizes_cache = {}

function Font.get(face, style, px)
    local fs = face .. "-" .. (STYLE_NAME[style] or "regular")
    local sizes = sizes_cache[fs]
    if not sizes then
        sizes = available_sizes(fs)
        if #sizes == 0 and style ~= "r" then return Font.get(face, style == "bi" and "b" or "r", px) end
        sizes_cache[fs] = sizes
    end
    if #sizes == 0 then error("no font files for " .. fs .. " in " .. font_dir) end
    local best = sizes[1]
    for _, s in ipairs(sizes) do
        if math.abs(s - px) < math.abs(best - px) then best = s end
    end
    local key = fs .. "-" .. best
    if loaded[key] then return loaded[key] end
    local raw = assert(util.read_file(font_dir .. "/" .. key .. ".tfnt"))
    local data = inflate.zlib_inflate(raw)
    assert(data:sub(1, 4) == "TFNT", "bad font file " .. key)
    local self = setmetatable({ name = key, glyphs = {} }, Font)
    self.size = rd(data, 5, "u16")
    self.ascent = rd(data, 7, "i16")
    self.descent = rd(data, 9, "i16")
    self.line_height = rd(data, 11, "u16")
    local n = rd(data, 13, "u32")
    local p = 17
    local blob_start = 17 + n * 20
    self.blob = ffi.new("uint8_t[?]", #data - blob_start + 1)
    ffi.copy(self.blob, ffi.cast("const uint8_t*", data) + blob_start - 1, #data - blob_start + 1)
    for _ = 1, n do
        local cp = rd(data, p, "u32")
        self.glyphs[cp] = {
            adv = rd(data, p + 4, "i32") / 64,
            left = rd(data, p + 8, "i16"),
            top = rd(data, p + 10, "i16"),
            w = rd(data, p + 12, "u16"),
            h = rd(data, p + 14, "u16"),
            off = rd(data, p + 16, "u32"),
        }
        p = p + 20
    end
    self.fallback = self.glyphs[0xFFFD] or self.glyphs[63]
    loaded[key] = self
    return self
end

function Font:glyph(cp)
    return self.glyphs[cp] or self.fallback
end

--- Width in pixels of a UTF-8 string.
function Font:width(s)
    local w = 0
    for _, cp in util.utf8_iter(s) do
        local g = self:glyph(cp)
        if g then w = w + g.adv end
    end
    return w
end

return Font
