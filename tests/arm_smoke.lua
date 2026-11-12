--[[
Smoke test for the cross-compiled Kindle binary, run in CI under qemu-arm:
  qemu-arm build/kindle/tome tests/arm_smoke.lua
Checks the static LuaJIT (with JIT and FFI) and the built-in tomecore module
can run Tome's core code paths on ARM.
--]]
package.path = "./?.lua;" .. package.path
local core = require("tomecore")
assert(type(core.monotonic_ms()) == "number", "tomecore clock")
assert(jit and jit.arch == "arm", "expected ARM LuaJIT, got " .. tostring(jit and jit.arch))
print("LuaJIT", jit.version, jit.arch, "JIT", jit.status() and "on" or "off")

local Font = require("tome.font"); Font.set_dir("fonts")
local Epub = require("tome.epub")
local Layout = require("tome.layout")
local Canvas = require("tome.canvas")
local Image = require("tome.image")

local book = assert(Epub.open("tests/fixtures/gulls_reach.epub"))
assert(book.title == "The Lighthouse at Gull's Reach", "title")
local layout = Layout.new({ width = 1072, height = 1448, margin_x = 60, margin_top = 60, margin_bottom = 120, font_size = 34 })
local pages = layout:paginate(book:chapter(1))
assert(#pages >= 1, "pagination")
local c = Canvas.new(1072, 1448)
layout:draw(c, pages[1])
local png = c:to_png()
assert(#png > 1000 and png:sub(2, 4) == "PNG", "png")
local img = assert(Image.decode(book:cover_data()), "cover decode")
assert(img.w == 1000 and img.h == 1500, "cover size")
-- error handling through LuaJIT's internal unwinder (LUAJIT_NO_UNWIND)
local ok, err = pcall(function() error("expected") end)
assert(not ok and tostring(err):find("expected"), "pcall/error")
book:close()
print("ARM smoke test OK")
