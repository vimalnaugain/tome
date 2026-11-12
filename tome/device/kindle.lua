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
local Rotation = require("tome.device.rotation")
local log = require("tome.log")
local util = require("tome.util")

local Kindle = { name = "kindle", is_kindle = true }
Kindle.__index = Kindle

local KEY_POWER = 116

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
    self.phys_w, self.phys_h = w or 1072, h or 1448
    self.width, self.height = self.phys_w, self.phys_h
    self.rotation = 0
    self.dpi = c.dpi or (math.min(self.phys_w, self.phys_h) >= 1000 and 300 or 167)
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
    if c.sleep_events ~= false then self:_listen_power() end
    -- Kindles with ads ("Special Offers") show an ad on the lock screen,
    -- which the system draws over anything we put there.
    local p = io.popen("lipc-get-prop com.lab126.blanket load 2>/dev/null")
    local blanket = p and p:read("*a") or ""
    if p then p:close() end
    self.special_offers = blanket:find("ad_screensaver") ~= nil
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
                -- Only take keys Tome uses (page turn, home, d-pad, menu, back).
                for code in pairs(self.keymap) do
                    if caps.key[code] then dev.keys = true; break end
                end
                -- The power button belongs to the Kindle: listen, never grab,
                -- or the system can no longer go to sleep (KOReader likewise
                -- leaves it alone).
                if caps.key[KEY_POWER] then dev.keys, dev.power = true, true end
            end
            if dev.touch or dev.keys then
                if self.config.grab_input ~= false and not dev.power then core.grab(fd, true) end
                dev.state = { x = 0, y = 0, down = false }
                self.inputs[#self.inputs + 1] = dev
                log.info(string.format("input %s (%s): %s%s range x=%s..%s y=%s..%s", path, name,
                    dev.touch and "touch" or (dev.power and "keys+power (not grabbed)" or "keys"), dev.mt and "/mt" or "",
                    tostring(dev.xmin), tostring(dev.xmax), tostring(dev.ymin), tostring(dev.ymax)))
            else
                core.close(fd)
            end
        end
    end
    if #self.inputs == 0 then log.warn("no input devices found") end
end

--- Power button / cover events from the Kindle's power daemon, via
-- `lipc-wait-event` writing into a FIFO we poll together with the touch
-- screen (KOReader does the same through a helper process).
function Kindle:_listen_power()
    local fifo = "/tmp/tome_power.fifo"
    os.execute("rm -f " .. fifo .. " && mkfifo " .. fifo)
    -- O_RDWR: the FIFO never reports end-of-file while we hold it open
    local fd = core.open(fifo, true, true)
    if not fd then log.warn("power events unavailable (no FIFO)"); return end
    os.execute("lipc-wait-event -m -s 0 com.lab126.powerd goingToScreenSaver,outOfScreenSaver > " .. fifo
        .. " 2>/dev/null & echo $! > /tmp/tome_power.pid")
    self.power_fd, self.power_fifo, self.power_buf = fd, fifo, ""
    log.info("listening for power events")
end

function Kindle:_read_power(out)
    local s = core.read(self.power_fd, 4096)
    if not s or s == "" then return end
    self.power_buf = self.power_buf .. s
    for line in self.power_buf:gmatch("([^\n]*)\n") do
        log.info("power event:", line)
        if line:find("^goingToScreenSaver") then out[#out + 1] = { type = "power", event = "sleep" }
        elseif line:find("^outOfScreenSaver") then out[#out + 1] = { type = "power", event = "wake" } end
    end
    self.power_buf = self.power_buf:match("[^\n]*$")
end

--- Ask the system to go to sleep, as if the power button was pressed.
function Kindle:suspend()
    -- our "keep awake" flag must not stand in the way
    self:prevent_sleep(false)
    sh("lipc-set-prop -i com.lab126.powerd powerButton 1")
end

--- Show a canvas in the panel's native orientation (sleep screen).
function Kindle:show_physical(canvas)
    local r = self.rotation
    self.rotation = 0
    self:refresh(canvas, "full")
    self.rotation = r
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
    local px, py = math.floor(sx * (self.phys_w - 1) + 0.5), math.floor(sy * (self.phys_h - 1) + 0.5)
    return Rotation.to_logical(px, py, self.phys_w, self.phys_h, self.rotation)
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
        elseif t == core.EV_KEY and value == 1 and code == KEY_POWER then
            out[#out + 1] = { type = "power_key" }
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
    if self.power_fd then fds[#fds + 1] = self.power_fd end
    local out = {}
    if #fds == 0 then core.sleep_ms(timeout_ms or 100); return out end
    local ready = core.poll(fds, timeout_ms or -1)
    local now = core.monotonic_ms()
    for _, dev in ipairs(self.inputs) do
        if ready[dev.fd] then self:_handle_events(dev, core.read_events(dev.fd), now, out) end
    end
    if self.power_fd and ready[self.power_fd] then self:_read_power(out) end
    return out
end

--- Push a canvas to the screen. mode: "full" (flash), "partial", "auto".
--- Set the screen orientation (0, 90, 180, 270). Views must re-layout after.
function Kindle:set_rotation(r)
    self.rotation = Rotation.normalize(r)
    self.width, self.height = Rotation.dims(self.phys_w, self.phys_h, self.rotation)
end

function Kindle:refresh(canvas, mode, region)
    local flash = mode == "full"
    if mode ~= "full" then
        self.updates_since_flash = self.updates_since_flash + 1
        if self.flash_every > 0 and self.updates_since_flash >= self.flash_every then flash = true end
    end
    if flash then self.updates_since_flash = 0 end
    canvas = Rotation.to_physical_canvas(canvas, self.phys_w, self.phys_h, self.rotation, self._phys_canvas)
    if canvas.w == self.phys_w and self.rotation ~= 0 then self._phys_canvas = canvas end
    if region and self.partial_updates and not flash and self.rotation == 0 then
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

------------------------------------------------------------------------------
-- Front light and warm light, through the power daemon (same properties
-- KOReader uses: flIntensity, currentAmberLevel). Levels are 0..max.
------------------------------------------------------------------------------
local function lipc_get_int(prop)
    local p = io.popen("lipc-get-prop -i com.lab126.powerd " .. prop .. " 2>/dev/null")
    if not p then return nil end
    local v = tonumber((p:read("*a") or ""):match("%-?%d+"))
    p:close()
    return v
end

function Kindle:frontlight()
    if self._fl_absent then return nil end
    local level = lipc_get_int("flIntensity")
    if not level then self._fl_absent = true; return nil end
    return { level = level, max = self.config.frontlight_max or 24 }
end

function Kindle:set_frontlight(level)
    sh("lipc-set-prop -i com.lab126.powerd flIntensity " .. math.floor(level))
end

--- Warm light (Oasis 3, Paperwhite Signature, Scribe...); nil if absent.
function Kindle:warmth()
    if self._warm_absent then return nil end
    local level = lipc_get_int("currentAmberLevel")
    if not level then self._warm_absent = true; return nil end
    return { level = level, max = self.config.warmth_max or 24 }
end

function Kindle:set_warmth(level)
    sh("lipc-set-prop -i com.lab126.powerd currentAmberLevel " .. math.floor(level))
end

------------------------------------------------------------------------------
-- Network helpers for the phone setup page.
------------------------------------------------------------------------------

--- IPv4 address on Wi-Fi, or nil when not connected.
function Kindle:wifi_ip()
    for _, cmd in ipairs({ "ifconfig wlan0 2>/dev/null", "ip -4 addr show wlan0 2>/dev/null" }) do
        local p = io.popen(cmd)
        local out = p and p:read("*a") or ""
        if p then p:close() end
        local ip = out:match("inet addr:(%d+%.%d+%.%d+%.%d+)") or out:match("inet (%d+%.%d+%.%d+%.%d+)")
        if ip and ip ~= "127.0.0.1" then return ip end
    end
end

-- The Kindle firewall drops incoming connections; open one port on Wi-Fi
-- only while the setup page runs (KOReader's SSH plugin does the same).
local function fw_rules(port)
    return {
        string.format("INPUT -i wlan0 -p tcp --dport %d -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT", port),
        string.format("OUTPUT -o wlan0 -p tcp --sport %d -m conntrack --ctstate ESTABLISHED -j ACCEPT", port),
    }
end

function Kindle:open_port(port)
    for _, r in ipairs(fw_rules(port)) do sh("iptables -I " .. r) end
end

function Kindle:close_port(port)
    for _, r in ipairs(fw_rules(port)) do sh("iptables -D " .. r) end
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
    if self.power_fd then
        local pid = tonumber(util.read_file("/tmp/tome_power.pid") or "")
        if pid then core.kill(pid) end
        core.close(self.power_fd)
        os.remove(self.power_fifo)
        self.power_fd = nil
    end
    self:prevent_sleep(false)
end

return Kindle
