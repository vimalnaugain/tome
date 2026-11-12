--[[
Screen orientation. Views always draw on a *logical* canvas (what the reader
sees upright); devices turn it into the panel's *physical* layout before
display, and turn touch coordinates back the other way.

rotation (degrees, clockwise turn of the content on the panel):
  0   portrait            90  landscape (content turned right)
  180 portrait flipped    270 landscape (content turned left)
--]]
local Canvas = require("tome.canvas")

local R = {}

R.NAMES = { [0] = "Portrait", [90] = "Landscape", [180] = "Portrait, upside down", [270] = "Landscape, flipped" }

function R.normalize(r)
    r = math.floor((tonumber(r) or 0) / 90 + 0.5) * 90 % 360
    return r
end

--- Logical size for a physical panel size and rotation.
function R.dims(pw, ph, r)
    if r == 90 or r == 270 then return ph, pw end
    return pw, ph
end

--- Physical touch point -> logical point.
function R.to_logical(px, py, pw, ph, r)
    if r == 90 then return py, pw - 1 - px end
    if r == 180 then return pw - 1 - px, ph - 1 - py end
    if r == 270 then return ph - 1 - py, px end
    return px, py
end

--- Logical point -> physical point (inverse of to_logical).
function R.to_physical(lx, ly, pw, ph, r)
    if r == 90 then return pw - 1 - ly, lx end
    if r == 180 then return pw - 1 - lx, ph - 1 - ly end
    if r == 270 then return ly, ph - 1 - lx end
    return lx, ly
end

--- Return a canvas in physical layout. `cache` is reused between calls.
function R.to_physical_canvas(canvas, pw, ph, r, cache)
    if r == 0 then return canvas end
    local dst = cache
    if not dst or dst.w ~= pw or dst.h ~= ph then dst = Canvas.new(pw, ph) end
    local src, out = canvas.buf, dst.buf
    local lw = canvas.w
    if r == 180 then
        local n = pw * ph
        for i = 0, n - 1 do out[n - 1 - i] = src[i] end
    elseif r == 90 then
        -- physical (px, py) shows logical (py, pw - 1 - px)
        for py = 0, ph - 1 do
            local row = py * pw
            for px = 0, pw - 1 do out[row + px] = src[(pw - 1 - px) * lw + py] end
        end
    else -- 270: physical (px, py) shows logical (ph - 1 - py, px)
        for py = 0, ph - 1 do
            local row = py * pw
            local lx = ph - 1 - py
            for px = 0, pw - 1 do out[row + px] = src[px * lw + lx] end
        end
    end
    return dst
end

return R
