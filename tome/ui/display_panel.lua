--[[
Display panel ("Aa"): a Kindle-style settings sheet at the bottom of the
screen. Every change applies to the page above immediately; the panel stays
open until you tap the page, the ✕, or press Back.

Tabs:
  Text    font, size, weight
  Layout  line spacing, margins, orientation
  Light   brightness, warm light (if the Kindle has it), contrast
--]]
local Font = require("tome.font")
local W = require("tome.ui.widgets")

local Panel = {}
Panel.__index = Panel

local TABS = { "Text", "Layout", "Light" }

function Panel.new(reader)
    local self = setmetatable({ reader = reader, app = reader.app, tab = 1, hits = {} }, Panel)
    -- read the lights once; the power daemon is slowish to query
    local d = reader.app.device
    self.light = d.frontlight and d:frontlight() or nil
    self.warm = d.warmth and d:warmth() or nil
    return self
end

function Panel:on_resize() end

------------------------------------------------------------------------------
-- Small drawing helpers. Each records its tap targets in self.hits.
------------------------------------------------------------------------------

function Panel:_hit(x, y, w, h, fn)
    self.hits[#self.hits + 1] = { x = x, y = y, w = w, h = h, fn = fn }
end

local function center_text(c, font, s, x, y, w, h, color)
    c:text(font, s, x + (w - font:width(s)) / 2, y + (h + font.ascent - font.descent) / 2, color)
end

--- Row label, returns y below it.
function Panel:_label(c, text, y)
    local t = self.t
    c:text(t.small, text, self.mx, y + t.small.ascent, 100)
    return y + t.small.line_height + math.floor(t.pad / 2)
end

--- Segmented control: options = { {label, value} }, returns y below.
function Panel:_segments(c, y, options, current, pick)
    local t = self.t
    local h = t.row_h
    local w = self.cw - 2 * self.mx
    local sw = w / #options
    for i, o in ipairs(options) do
        local x = math.floor(self.mx + (i - 1) * sw)
        local bw = math.floor(self.mx + i * sw) - x
        local on = o[2] == current
        c:fill_rect(x, y, bw, h, on and 0 or 255)
        c:rect(x, y, bw, h, 0, t.border)
        center_text(c, t.font, W.fit(t.font, o[1], bw - t.pad), x, y, bw, h, on and 255 or 0)
        self:_hit(x, y, bw, h, function() pick(o[2]) end)
    end
    return y + h + t.pad
end

--- Stepper: [ minus ]  value  [ plus ], returns y below.
function Panel:_stepper(c, y, minus_label, value_label, plus_label, on_minus, on_plus)
    local t = self.t
    local h = t.row_h
    local bw = math.floor((self.cw - 2 * self.mx) * 0.3)
    W.draw_button(c, { x = self.mx, y = y, w = bw, h = h }, minus_label, t.bold, false, t.border)
    self:_hit(self.mx, y, bw, h, on_minus)
    local rx = self.cw - self.mx - bw
    W.draw_button(c, { x = rx, y = y, w = bw, h = h }, plus_label, t.bold, false, t.border)
    self:_hit(rx, y, bw, h, on_plus)
    center_text(c, t.title, value_label, self.mx + bw, y, rx - self.mx - bw, h, 0)
    return y + h + t.pad
end

--- Slider 0..max with − / + buttons; tapping the bar jumps there.
function Panel:_slider(c, y, level, max, set)
    local t = self.t
    local h = t.row_h
    local bw = h
    local function clamp(v) return math.max(0, math.min(max, v)) end
    W.draw_button(c, { x = self.mx, y = y, w = bw, h = h }, "\226\128\147", t.title, false, t.border) -- −
    self:_hit(self.mx, y, bw, h, function() set(clamp(level - 1)) end)
    local px = self.cw - self.mx - bw
    W.draw_button(c, { x = px, y = y, w = bw, h = h }, "+", t.title, false, t.border)
    self:_hit(px, y, bw, h, function() set(clamp(level + 1)) end)
    local bx, bwid = self.mx + bw + t.pad * 2, px - self.mx - bw - t.pad * 4
    local by = y + math.floor(h / 2) - t.border * 2
    c:fill_rect(bx, by, bwid, t.border * 4, 210)
    c:fill_rect(bx, by, math.floor(bwid * level / max), t.border * 4, 0)
    local kx = bx + math.floor(bwid * level / max)
    c:fill_rect(kx - t.pad / 2, y + t.pad, t.pad, h - 2 * t.pad, 0)
    self:_hit(bx - t.pad, y, bwid + 2 * t.pad, h, function(ev)
        set(clamp(math.floor((ev.x - bx) / bwid * max + 0.5)))
    end)
    return y + h + t.pad
end

------------------------------------------------------------------------------
-- Tabs
------------------------------------------------------------------------------

function Panel:_text_tab(c, y)
    local r, disp, t = self.reader, self.reader.display, self.t
    -- Fonts: chips, each label set in its own typeface
    y = self:_label(c, "Font", y)
    local faces = r.FACES
    local per_row = 4
    local cw = (self.cw - 2 * self.mx) / per_row
    local ch = t.row_h
    for i, f in ipairs(faces) do
        local col, row = (i - 1) % per_row, math.floor((i - 1) / per_row)
        local x = math.floor(self.mx + col * cw)
        local yy = y + row * (ch + math.floor(t.pad / 2))
        local w = math.floor(self.mx + (col + 1) * cw) - x - math.floor(t.pad / 2)
        local on = disp.face == f[1]
        c:fill_rect(x, yy, w, ch, on and 0 or 255)
        c:rect(x, yy, w, ch, 0, t.border)
        local ff = Font.get(f[1], "r", math.floor(self.app.device.dpi * 0.09))
        local name = f[2]:gsub(" Hyperlegible", "")
        center_text(c, ff, W.fit(ff, name, w - t.pad), x, yy, w, ch, on and 255 or 0)
        self:_hit(x, yy, w, ch, function() r:_set("face", f[1]) end)
    end
    y = y + math.ceil(#faces / per_row) * (ch + math.floor(t.pad / 2)) + t.pad

    y = self:_label(c, "Size", y)
    local sizes = r.FONT_SIZES
    local idx = 1
    for i, s in ipairs(sizes) do if s == disp.font_size then idx = i end end
    y = self:_stepper(c, y, "A\226\128\147", tostring(disp.font_size), "A+",
        function() if idx > 1 then r:_set("font_size", sizes[idx - 1]) end end,
        function() if idx < #sizes then r:_set("font_size", sizes[idx + 1]) end end)

    y = self:_label(c, "Weight", y)
    y = self:_segments(c, y, { { "Regular", 0 }, { "Bolder", 1 }, { "Boldest", 2 } }, disp.weight or 0,
        function(v) r:_set("weight", v) end)
    return y
end

function Panel:_layout_tab(c, y)
    local r, disp = self.reader, self.reader.display
    y = self:_label(c, "Line spacing", y)
    y = self:_segments(c, y, { { "Tight", 1.15 }, { "Normal", 1.3 }, { "Relaxed", 1.45 }, { "Loose", 1.6 } },
        disp.line_spacing, function(v) r:_set("line_spacing", v) end)
    y = self:_label(c, "Margins", y)
    y = self:_segments(c, y, { { "Narrow", "narrow" }, { "Medium", "medium" }, { "Wide", "wide" } },
        disp.margins, function(v) r:_set("margins", v) end)
    y = self:_label(c, "Orientation", y)
    local rot = self.app.device.rotation or 0
    local landscape = rot == 90 or rot == 270
    y = self:_segments(c, y, { { "Portrait", false }, { "Landscape", true }, { "Turn 180\194\176", "flip" } },
        landscape, function(v)
            if v == "flip" then self.app:set_rotation((rot + 180) % 360)
            elseif v ~= landscape then self.app:set_rotation(v and 90 or 0) end
        end)
    return y
end

function Panel:_light_tab(c, y)
    local t, d = self.t, self.app.device
    if self.light then
        y = self:_label(c, string.format("Brightness  %d", self.light.level), y)
        y = self:_slider(c, y, self.light.level, self.light.max, function(v)
            self.light.level = v
            d:set_frontlight(v)
        end)
    else
        y = self:_label(c, "This Kindle has no front light.", y)
    end
    if self.warm then
        y = self:_label(c, string.format("Warmth  %d", self.warm.level), y)
        y = self:_slider(c, y, self.warm.level, self.warm.max, function(v)
            self.warm.level = v
            d:set_warmth(v)
        end)
    end
    y = self:_label(c, "Contrast", y)
    y = self:_segments(c, y, { { "Normal", 0 }, { "Darker", 1 }, { "Darkest", 2 } }, self.app.settings.contrast or 0,
        function(v)
            self.app.settings.contrast = v
            self.app:save_settings()
            self.ui:set_contrast(v)
        end)
    local _ = t
    return y
end

------------------------------------------------------------------------------

function Panel:draw(c)
    local t = W.theme(self.ui)
    self.t, self.cw, self.mx = t, c.w, t.pad * 2
    self.hits = {}
    -- Measure by drawing on a scratch pass would be costly; use a fixed
    -- height that fits the tallest tab, anchored to the bottom.
    local h = math.min(math.floor(c.h * 0.62), t.bar_h + 3 * (t.small.line_height + t.row_h + t.pad * 2) + 2 * t.row_h)
    local y0 = c.h - h
    self.rect = { x = 0, y = y0, w = c.w, h = h }
    c:fill_rect(0, y0, c.w, h, 255)
    c:fill_rect(0, y0, c.w, t.border * 2, 0)

    -- tab bar + close
    local tab_w = math.floor((c.w - t.bar_h) / #TABS)
    for i, name in ipairs(TABS) do
        local x = (i - 1) * tab_w
        local on = i == self.tab
        center_text(c, on and t.bold or t.font, name, x, y0 + t.border * 2, tab_w, t.bar_h, on and 0 or 110)
        if on then c:fill_rect(x + t.pad, y0 + t.bar_h - t.border * 3, tab_w - 2 * t.pad, t.border * 3, 0) end
        self:_hit(x, y0, tab_w, t.bar_h, function() self.tab = i end)
    end
    center_text(c, t.title, "\195\151", c.w - t.bar_h, y0, t.bar_h, t.bar_h, 0)
    self:_hit(c.w - t.bar_h, y0, t.bar_h, t.bar_h, function() self.ui:close(self) end)
    c:fill_rect(0, y0 + t.bar_h, c.w, 1, 200)

    local y = y0 + t.bar_h + t.pad
    if self.tab == 1 then self:_text_tab(c, y)
    elseif self.tab == 2 then self:_layout_tab(c, y)
    else self:_light_tab(c, y) end
end

function Panel:handle(ev)
    if ev.type == "key" then
        if ev.key == "back" or ev.key == "menu" then self.ui:close(self) end
        return true
    end
    if ev.type ~= "tap" then return true end
    if not W.inside(ev, self.rect) then
        self.ui:close(self) -- tap on the page: done
        return true
    end
    for i = #self.hits, 1, -1 do
        local h = self.hits[i]
        if W.inside(ev, h) then
            h.fn(ev)
            self.ui:set_dirty("partial")
            return true
        end
    end
    return true
end

return Panel
