--[[
Draws Tome's 250x250 library icon (a book with a "T") as a PNG using Tome's
own canvas and fonts. Usage: luajit tools/make_icon.lua out.png
--]]
package.path = "./?.lua;" .. package.path
local Canvas = require("tome.canvas")
local Font = require("tome.font")
Font.set_dir("fonts")

local c = Canvas.new(250, 250)
c:fill_rect(0, 0, 250, 250, 255)
-- book: cover with a spine and page edges
c:fill_rect(52, 30, 150, 190, 30)
c:fill_rect(52, 30, 14, 190, 0)
c:fill_rect(66, 214, 136, 10, 210)
c:rect(52, 30, 150, 194, 0, 3)
local t = "T"
local big = Font.get("charter", "b", 54)
c:text(big, t, 134 - big:width(t) / 2, 145, 255)
c:fill_rect(98, 160, 72, 3, 235)
local out = assert(io.open(arg[1] or "tome-icon.png", "wb"))
out:write(c:to_png())
out:close()
