--[[
Jailbroken Kindle (firmware 5.x, touch models).

Display: the screen is drawn into a Canvas, written as PNG to /tmp and shown
with Amazon's own `eips -g` tool. That sidesteps the per-generation mxcfb
ioctl differences (Zelda/Rex/MTK/...) KOReader handles in
koreader-base/ffi/framebuffer_mxcfb.lua, at the cost of some refresh speed.

Input: evdev via the tomecore C module (poll + EVIOCGRAB), multitouch
protocol B or single-touch ABS_X/Y, scaled using EVIOCGABS ranges.
--]]
local core = require("tomecore")
local Gestures = require("tome.device.gestures")
local log = require("tome.log")
local util = require("tome.util")

local Kindle = { name = "kindle", is_kindle = true }
Kindle.__index = Kindle

local DEFAULT_KEYS = {
    [104] = "next", [109] = "prev", [191] = "next", [193] = "prev",
    [102] = "home", [139] = "menu", [158] = "back",
    [103] = "up", [108] = "down", [105] = "left", [106] = "right", [28] = "select",
}

local function sh(cmd)
    log.debug("sh:", cmd)
    return os.execute(cmd .. " >/dev/null 2>&1")
end

local function read_first_line(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local l = f:read("*l")
    f:close()
    return l
end

function Kindle.detect()
    return util.file_exists("/usr/sbin/eips") or util.file_exists("/proc/usid")
end

function Kindle.new(config)
    local self = setmetatable({ config = config or {} }, Kindle)
    local c = self.config

    local fb = core.fbinfo("/dev/fb0")
    local w, h = c.screen_width, c.screen_height
    if fb then
        w = w or fb.xres
        h = h or fb.yres
        log.info(string.format("fb0: %dx%d bpp=%d line=%d rotate=%d", fb.xres, fb.yres, fb.bpp, fb.line_length, fb.rotate))
    end
    self.width, self.height = w or 1072, h or 1448
    self.dpi = c.dpi or (self.width >= 1000 and 300 or 167)
    self.eips = c.eips_path or "/usr/sbin/eips"
    self.png_path = c.screen_png or "/tmp/tome_screen.png"
    self.flash_every = c.flash_every or 6
    self.partial_updates = c.eips_partial == true
    self.updates_since_flash = 0

    self.keymap = {}
    for k, v in pairs(DEFAULT_KEYS) do self.keymap[k] = v end
    for k, v in pairs(c.keymap or {}) do self.keymap[tonumber(k)] = v end

    self.gestures = Gestures.new({ tap_slop = math.floor(self.dpi / 10) })
    self:_open_inputs()
    return self
end

function Kindle:_open_inputs()
    self.inputs = {}
    local paths = self.config.input_devices
    if not paths then
        paths = {}
        for i = 0, 9 do paths[#paths + 1] = "/dev/input/event" .. i end
    end
    for _, path in ipairs(paths) do
        local fd = core.open(path, false, true)
        if fd then
            local caps = core.caps(fd)
            local name = core.name(fd) or "?"
            local dev = { fd = fd, path = path, name = name }
            if caps and caps.ev[core.EV_ABS] and (caps.abs[core.ABS_MT_POSITION_X] or caps.abs[core.ABS_X]) then
                dev.touch = true
                dev.mt = caps.abs[core.ABS_MT_POSITION_X] and true or false
                local ax = dev.mt and core.ABS_MT_POSITION_X or core.ABS_X
                local ay = dev.mt and core.ABS_MT_POSITION_Y or core.ABS_Y
                dev.xmin, dev.xmax = core.absinfo(fd, ax)
                dev.ymin, dev.ymax = core.absinfo(fd, ay)
            elseif caps and caps.ev[core.EV_KEY] and caps.nkeys > 0 then
                dev.keys = true
            end
            if dev.touch or dev.keys then
                if self.config.grab_input ~= false then core.grab(fd, true) end
                dev.state = { x = 0, y = 0, down = false }
                self.inputs[#self.inputs + 1] = dev
                log.info(string.format("input %s (%s): %s%s range x=%s..%s y=%s..%s", path, name,
                    dev.touch and "touch" or "keys", dev.mt and "/mt" or "",
                    tostring(dev.xmin), tostring(dev.xmax), tostring(dev.ymin), tostring(dev.ymax)))
            else
                core.close(fd)
            end
        end
    end
    if #self.inputs == 0 then log.warn("no input devices found") end
end

--- Map raw touch coordinates to screen pixels.
function Kindle:_scale(dev, rx, ry)
    local c = self.config
    local x, y = rx, ry
    local xmin, xmax, ymin, ymax = dev.xmin or 0, dev.xmax or self.width - 1, dev.ymin or 0, dev.ymax or self.height - 1
    if c.touch_swap_xy then
        x, y = ry, rx
        xmin, xmax, ymin, ymax = ymin, ymax, xmin, xmax
    end
    local sx = (xmax > xmin) and (x - xmin) / (xmax - xmin) or 0
    local sy = (ymax > ymin) and (y - ymin) / (ymax - ymin) or 0
    if c.touch_mirror_x then sx = 1 - sx end
    if c.touch_mirror_y then sy = 1 - sy end
    return math.floor(sx * (self.width - 1) + 0.5), math.floor(sy * (self.height - 1) + 0.5)
end

--- Translate raw evdev events from one device into gesture/key events.
-- Split out from poll() so it can be tested with synthetic events.
function Kindle:_handle_events(dev, events, now, out)
    local st = dev.state
    for _, ev in ipairs(events) do
        local t, code, value = ev[1], ev[2], ev[3]
        if dev.touch then
            if t == core.EV_ABS then
                if code == core.ABS_MT_POSITION_X or code == core.ABS_X then st.x = value; st.moved = true
                elseif code == core.ABS_MT_POSITION_Y or code == core.ABS_Y then st.y = value; st.moved = true
                elseif code == core.ABS_MT_TRACKING_ID then
                    if value == -1 then st.pending_up = true else st.pending_down = true end
                end
            elseif t == core.EV_KEY and code == core.BTN_TOUCH then
                if value == 0 then st.pending_up = true else st.pending_down = true end
            elseif t == core.EV_SYN and code == core.SYN_REPORT then
                local x, y = self:_scale(dev, st.x, st.y)
                if st.pending_down and not st.down then
                    st.down = true
                    self.gestures:touch_down(x, y, now)
                elseif st.moved and st.down then
                    self.gestures:touch_move(x, y)
                end
                if st.pending_up and st.down then
                    st.down = false
                    local g = self.gestures:touch_up(now)
                    if g then out[#out + 1] = g end
                end
                st.pending_down, st.pending_up, st.moved = false, false, false
            end
        elseif t == core.EV_KEY and value == 1 then
            local name = self.keymap[code]
            log.debug("key", code, name)
            if name then out[#out + 1] = { type = "key", key = name } end
        end
    end
    return out
end

--- Wait up to timeout_ms for input. Returns a list of events.
function Kindle:poll(timeout_ms)
    local fds = {}
    for _, d in ipairs(self.inputs) do fds[#fds + 1] = d.fd end
    local out = {}
    if #fds == 0 then core.sleep_ms(timeout_ms or 100); return out end
    local ready = core.poll(fds, timeout_ms or -1)
    local now = core.monotonic_ms()
    for _, dev in ipairs(self.inputs) do
        if ready[dev.fd] then self:_handle_events(dev, core.read_events(dev.fd), now, out) end
    end
    return out
end

--- Push a canvas to the screen. mode: "full" (flash), "partial", "auto".
function Kindle:refresh(canvas, mode, region)
    local flash = mode == "full"
    if mode ~= "full" then
        self.updates_since_flash = self.updates_since_flash + 1
        if self.flash_every > 0 and self.updates_since_flash >= self.flash_every then flash = true end
    end
    if flash then self.updates_since_flash = 0 end
    if region and self.partial_updates and not flash then
        local png = canvas:to_png(region.x, region.y, region.w, region.h)
        util.write_file(self.png_path, png)
        sh(string.format("%s -x %d -y %d -g %s", self.eips, region.x, region.y, self.png_path))
    else
        util.write_file(self.png_path, canvas:to_png())
        sh(string.format("%s %s-g %s", self.eips, flash and "-f " or "", self.png_path))
    end
end

function Kindle:battery()
    for _, p in ipairs({
        "/sys/class/power_supply/bd71827_bat/capacity",
        "/sys/class/power_supply/max77796-battery/capacity",
        "/sys/class/power_supply/max77696-battery/capacity",
        "/sys/devices/system/wario_battery/wario_battery0/battery_capacity",
        "/sys/devices/system/yoshi_battery/yoshi_battery0/battery_capacity",
    }) do
        local v = read_first_line(p)
        if v then return tonumber(v:match("%d+")) end
    end
end

--- Keep the Kindle from going to its screensaver while Tome runs.
function Kindle:prevent_sleep(on)
    sh("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (on and "1" or "0"))
end

function Kindle:wifi_enable()
    sh("lipc-set-prop com.lab126.cmd wirelessEnable 1")
end

function Kindle:monotonic_ms() return core.monotonic_ms() end
function Kindle:sleep_ms(ms) core.sleep_ms(ms) end

function Kindle:close()
    for _, d in ipairs(self.inputs or {}) do
        core.grab(d.fd, false)
        core.close(d.fd)
    end
    self.inputs = {}
    self:prevent_sleep(false)
end

return Kindle
