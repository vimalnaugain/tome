--[[
Turns raw touch down/move/up into tap / hold / swipe events.
--]]
local Gestures = {}
Gestures.__index = Gestures

function Gestures.new(opts)
    return setmetatable({
        tap_slop = opts and opts.tap_slop or 30,       -- px a finger may wander and still "tap"
        hold_ms = opts and opts.hold_ms or 650,
        down = nil,
    }, Gestures)
end

function Gestures:touch_down(x, y, t)
    self.down = { x = x, y = y, t = t, lx = x, ly = y }
end

function Gestures:touch_move(x, y)
    if self.down then self.down.lx, self.down.ly = x, y end
end

--- Returns a gesture event or nil.
function Gestures:touch_up(t)
    local d = self.down
    self.down = nil
    if not d then return nil end
    local dx, dy = d.lx - d.x, d.ly - d.y
    if math.abs(dx) <= self.tap_slop and math.abs(dy) <= self.tap_slop then
        if t - d.t >= self.hold_ms then return { type = "hold", x = d.x, y = d.y } end
        return { type = "tap", x = d.x, y = d.y }
    end
    local dir
    if math.abs(dx) > math.abs(dy) then dir = dx < 0 and "left" or "right" else dir = dy < 0 and "up" or "down" end
    return { type = "swipe", dir = dir, x = d.x, y = d.y, dx = dx, dy = dy }
end

return Gestures
