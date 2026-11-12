--[[
Desktop emulator. Two input modes:

  * script: reads commands from a file (or stdin) -- used for automated tests
      tap X Y | hold X Y | swipe left|right|up|down | key NAME
      wait MS | idle (wait for background tasks) | shot NAME | quit
    Every refresh is written to <out_dir>/screen.png; `shot` saves a copy.
  * sdl: an SDL2 window (via LuaJIT FFI, desktop only). Click = tap,
    right-click = hold, drag = swipe, arrows/PgUp/PgDn/Esc/m = keys.
--]]
local ok_core, core = pcall(require, "tomecore")
local util = require("tome.util")
local log = require("tome.log")

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
    self.width = c.screen_width or 1072
    self.height = c.screen_height or 1448
    self.dpi = c.dpi or 300
    self.out_dir = c.out_dir or "emu_out"
    util.mkdir_p(self.out_dir)
    self.refresh_count = 0
    self.mode = c.input or "script"
    if self.mode == "sdl" then
        self.sdl = require("tome.device.sdl").new(self.width, self.height, c.sdl_scale or 0.5)
    else
        local src = c.script and io.open(c.script, "r") or io.stdin
        self.script = src
    end
    return self
end

function Emu:monotonic_ms() return now_ms() end
function Emu:sleep_ms(ms) sleep_ms(ms) end

function Emu:refresh(canvas, mode)
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
        return { { type = op, x = tonumber(cmd[2]), y = tonumber(cmd[3]) } }
    elseif op == "swipe" then
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
    elseif op == "quit" then
        return { { type = "quit" } }
    end
    log.warn("unknown script command", op)
    return {}
end

function Emu:battery() return 87 end
function Emu:prevent_sleep() end
function Emu:wifi_enable() end
function Emu:close()
    if self.sdl then self.sdl:close() end
end

return Emu
