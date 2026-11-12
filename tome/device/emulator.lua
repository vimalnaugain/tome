--[[
Desktop emulator. Two input modes:

  * script: reads commands from a file (or stdin) -- used for automated tests
      tap X Y | hold X Y | swipe left|right|up|down | key NAME
      wait MS | idle (wait for background tasks) | shot NAME | quit
      sleep | wake (power button)
    Every refresh is written to <out_dir>/screen.png; `shot` saves a copy.
  * sdl: an SDL2 window (via LuaJIT FFI, desktop only). Click = tap,
    right-click = hold, drag = swipe, arrows/PgUp/PgDn/Esc/m = keys.
--]]
local ok_core, core = pcall(require, "tomecore")
local util = require("tome.util")
local log = require("tome.log")
local Rotation = require("tome.device.rotation")

local Emu = { name = "emulator", is_kindle = false }
Emu.__index = Emu

local function now_ms()
    if ok_core then return core.monotonic_ms() end
    return os.clock() * 1000
end

local function sleep_ms(ms)
    if ok_core then core.sleep_ms(ms) else os.execute("sleep " .. ms / 1000) end
end

function Emu.new(config)
    local c = config or {}
    local self = setmetatable({ config = c }, Emu)
    self.phys_w = c.screen_width or 1072
    self.phys_h = c.screen_height or 1448
    self.width, self.height, self.rotation = self.phys_w, self.phys_h, 0
    self.dpi = c.dpi or 300
    self.out_dir = c.out_dir or "emu_out"
    util.mkdir_p(self.out_dir)
    self.refresh_count = 0
    self.mode = c.input or "script"
    if self.mode == "sdl" then
        self.sdl = require("tome.device.sdl").new(self.phys_w, self.phys_h, c.sdl_scale or 0.5)
        self.sdl.to_logical = function(x, y) return Rotation.to_logical(x, y, self.phys_w, self.phys_h, self.rotation) end
    else
        local src = c.script and io.open(c.script, "r") or io.stdin
        self.script = src
    end
    return self
end

function Emu:monotonic_ms() return now_ms() end
function Emu:sleep_ms(ms) sleep_ms(ms) end

function Emu:set_rotation(r)
    self.rotation = Rotation.normalize(r)
    self.width, self.height = Rotation.dims(self.phys_w, self.phys_h, self.rotation)
end

--- What the panel shows (physical layout), for screenshots.
function Emu:refresh(canvas, mode)
    canvas = Rotation.to_physical_canvas(canvas, self.phys_w, self.phys_h, self.rotation)
    self.canvas = canvas
    self.refresh_count = self.refresh_count + 1
    if self.sdl then
        self.sdl:present(canvas)
    else
        util.write_file(self.out_dir .. "/screen.png", canvas:to_png())
    end
    log.debug("refresh", self.refresh_count, mode)
end

function Emu:_next_command()
    if not self.script then return nil end
    while true do
        local line = self.script:read("*l")
        if not line then return { "quit" } end
        line = line:gsub("#.*$", "")
        local words = {}
        for w in line:gmatch("%S+") do words[#words + 1] = w end
        if #words > 0 then return words end
    end
end

--- `busy_fn` is set by the app: returns true while background tasks run.
function Emu:poll(timeout_ms)
    if self.pending_power then
        local ev = self.pending_power
        self.pending_power = nil
        return { ev }
    end
    if self.sdl then return self.sdl:poll(timeout_ms) end
    if self.waiting_until then
        if now_ms() < self.waiting_until then
            sleep_ms(math.min(timeout_ms or 50, self.waiting_until - now_ms()))
            return {}
        end
        self.waiting_until = nil
    end
    if self.waiting_idle then
        if self.busy_fn and self.busy_fn() then
            sleep_ms(math.min(timeout_ms or 50, 50))
            return {}
        end
        self.waiting_idle = false
    end
    local cmd = self:_next_command()
    local op = cmd[1]
    log.info("script:", table.concat(cmd, " "))
    if op == "tap" or op == "hold" then
        -- script coordinates are physical (as on the panel), like real touches
        local x, y = Rotation.to_logical(tonumber(cmd[2]), tonumber(cmd[3]), self.phys_w, self.phys_h, self.rotation)
        return { { type = op, x = x, y = y } }
    elseif op == "swipe" then
        -- direction is as seen by the reader
        return { { type = "swipe", dir = cmd[2], x = self.width / 2, y = self.height / 2 } }
    elseif op == "key" then
        return { { type = "key", key = cmd[2] } }
    elseif op == "wait" then
        self.waiting_until = now_ms() + (tonumber(cmd[2]) or 100)
        return {}
    elseif op == "idle" then
        self.waiting_idle = true
        return {}
    elseif op == "shot" then
        if self.canvas then
            util.write_file(self.out_dir .. "/" .. (cmd[2] or "shot") .. ".png", self.canvas:to_png())
        end
        return {}
    elseif op == "sleep" or op == "wake" then
        -- simulate the power button
        return { { type = "power", event = op } }
    elseif op == "quit" then
        return { { type = "quit" } }
    end
    log.warn("unknown script command", op)
    return {}
end

function Emu:battery() return 87 end

-- Simulated lights, so the display panel can be exercised on a desktop.
function Emu:frontlight()
    self.fl = self.fl or 12
    return { level = self.fl, max = 24 }
end
function Emu:set_frontlight(level) self.fl = level end
function Emu:warmth()
    if self.config.no_warmth then return nil end
    self.warm = self.warm or 6
    return { level = self.warm, max = 24 }
end
function Emu:set_warmth(level) self.warm = level end
--- The emulator "suspends" by delivering the sleep event the Kindle would send.
function Emu:suspend() self.pending_power = { type = "power", event = "sleep" } end

function Emu:show_physical(canvas)
    local r = self.rotation
    self.rotation = 0
    self:refresh(canvas, "full")
    self.rotation = r
end
function Emu:prevent_sleep() end
function Emu:wifi_enable() end
function Emu:close()
    if self.sdl then self.sdl:close() end
end

return Emu
