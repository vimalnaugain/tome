--[[
Minimal e-ink widget set: Menu, ListView, TextViewer, Message, Progress,
Confirm. All sizes derive from the screen DPI so touch targets stay ~9 mm.
--]]
local Font = require("tome.font")
local Layout = require("tome.layout")

local W = {}

--- Theme (computed once per UI).
function W.theme(ui)
    if ui.theme then return ui.theme end
    local dpi = ui.device.dpi
    local t = {
        font = Font.get("sans", "r", math.floor(dpi * 0.105)),
        bold = Font.get("sans", "b", math.floor(dpi * 0.105)),
        small = Font.get("sans", "r", math.floor(dpi * 0.08)),
        title = Font.get("sans", "b", math.floor(dpi * 0.125)),
        row_h = math.floor(dpi * 0.36),
        pad = math.floor(dpi * 0.08),
        border = math.max(2, math.floor(dpi / 100)),
        bar_h = math.floor(dpi * 0.4),
    }
    ui.theme = t
    return t
end

local function inside(ev, r)
    return ev.x and ev.x >= r.x and ev.x < r.x + r.w and ev.y >= r.y and ev.y < r.y + r.h
end
W.inside = inside

--- Truncate text with an ellipsis to fit width.
local function fit(font, s, maxw)
    if font:width(s) <= maxw then return s end
    local ell = "\226\128\166"
    local out = s
    while #out > 0 and font:width(out .. ell) > maxw do
        out = out:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
    end
    return out .. ell
end
W.fit = fit

--- Word-wrap plain text into lines for a font and width.
local function wrap(font, text, maxw)
    local lines = {}
    for para in (text .. "\n"):gmatch("(.-)\n") do
        local line = ""
        for word in para:gmatch("%S+") do
            local cand = line == "" and word or line .. " " .. word
            if font:width(cand) > maxw and line ~= "" then
                lines[#lines + 1] = line
                line = word
            else
                line = cand
            end
        end
        lines[#lines + 1] = line
    end
    return lines
end
W.wrap = wrap

local function draw_button(c, r, label, font, inverted, border)
    c:fill_rect(r.x, r.y, r.w, r.h, inverted and 0 or 255)
    c:rect(r.x, r.y, r.w, r.h, 0, border)
    local tw = font:width(label)
    c:text(font, label, r.x + (r.w - tw) / 2, r.y + (r.h + font.ascent - font.descent) / 2, inverted and 255 or 0)
end
W.draw_button = draw_button

------------------------------------------------------------------------------
-- Title bar shared by full-screen views: [title ............ ✕]
------------------------------------------------------------------------------
local function title_bar(view, c, title)
    local t = W.theme(view.ui)
    local w = c.w
    c:fill_rect(0, 0, w, t.bar_h, 255)
    c:text(t.title, fit(t.title, title or "", w - t.bar_h - 2 * t.pad), t.pad, (t.bar_h + t.title.ascent - t.title.descent) / 2)
    view.close_rect = { x = w - t.bar_h, y = 0, w = t.bar_h, h = t.bar_h }
    local x_label = "\195\151" -- ×
    c:text(t.title, x_label, w - t.bar_h + (t.bar_h - t.title:width(x_label)) / 2, (t.bar_h + t.title.ascent - t.title.descent) / 2)
    c:fill_rect(0, t.bar_h - t.border, w, t.border, 0)
end

local function page_footer(view, c, page, pages)
    local t = W.theme(view.ui)
    local y = c.h - t.bar_h
    c:fill_rect(0, y, c.w, t.border, 0)
    view.prev_rect = { x = 0, y = y, w = c.w / 3, h = t.bar_h }
    view.next_rect = { x = c.w * 2 / 3, y = y, w = c.w / 3, h = t.bar_h }
    local base = y + (t.bar_h + t.font.ascent - t.font.descent) / 2
    local label = string.format("%d / %d", page, pages)
    c:text(t.font, label, (c.w - t.font:width(label)) / 2, base)
    if page > 1 then c:text(t.title, "\226\151\128", t.pad * 2, base) end           -- ◀ (fallback glyph if missing)
    if page < pages then c:text(t.title, "\226\150\182", c.w - t.pad * 2 - t.title:width("\226\150\182"), base) end
end

------------------------------------------------------------------------------
-- Menu: overlay panel anchored to the top of the screen.
-- items = { {text=, callback=, submenu=, checked=fn|bool, enabled=fn|bool, keep_open=bool} }
------------------------------------------------------------------------------
local Menu = {}
Menu.__index = Menu
W.Menu = Menu

function Menu.new(opts)
    return setmetatable({ title = opts.title, items = opts.items, page = 1, parent = opts.parent }, Menu)
end

local function resolve(v) if type(v) == "function" then return v() end return v end

function Menu:_geometry(c)
    local t = W.theme(self.ui)
    local avail = c.h * 0.8 - t.bar_h
    self.per_page = math.max(1, math.floor(avail / t.row_h))
    self.pages = math.max(1, math.ceil(#self.items / self.per_page))
    local rows = math.min(#self.items, self.per_page)
    local h = t.bar_h + rows * t.row_h + (self.pages > 1 and t.row_h or 0)
    return { x = 0, y = 0, w = c.w, h = h }
end

function Menu:on_close()
    if self.parent then self.parent.hidden = false end
end

function Menu:draw(c)
    if self.hidden then return end -- a submenu is open on top of us
    local t = W.theme(self.ui)
    local r = self:_geometry(c)
    self.rect = r
    c:fill_rect(r.x, r.y, r.w, r.h, 255)
    title_bar(self, c, self.title or "Menu")
    self.rows = {}
    local first = (self.page - 1) * self.per_page + 1
    local y = t.bar_h
    for i = first, math.min(#self.items, first + self.per_page - 1) do
        local it = self.items[i]
        local enabled = it.enabled == nil or resolve(it.enabled)
        local row = { x = 0, y = y, w = c.w, h = t.row_h, item = it, enabled = enabled }
        self.rows[#self.rows + 1] = row
        local label = resolve(it.text) or "?"
        local font = t.font
        local color = enabled and 0 or 150
        local base = y + (t.row_h + font.ascent - font.descent) / 2
        local right = ""
        if it.submenu then right = "\226\150\182" end
        local checked = it.checked ~= nil and resolve(it.checked)
        if checked then right = "\226\156\147" end
        c:text(font, fit(font, label, c.w - 4 * t.pad - font:width(right)), 2 * t.pad, base, color)
        if right ~= "" then c:text(t.bold, right, c.w - 2 * t.pad - t.bold:width(right), base, color) end
        c:fill_rect(t.pad, y + t.row_h - 1, c.w - 2 * t.pad, 1, 200)
        y = y + t.row_h
    end
    if self.pages > 1 then
        local label = string.format("\226\151\128   %d / %d   \226\150\182", self.page, self.pages)
        c:text(t.font, label, (c.w - t.font:width(label)) / 2, y + (t.row_h + t.font.ascent) / 2)
        self.pager_rect = { x = 0, y = y, w = c.w, h = t.row_h }
    end
    c:fill_rect(0, r.h - t.border, c.w, t.border, 0)
end

function Menu:handle(ev)
    if ev.type == "key" then
        if ev.key == "back" or ev.key == "menu" then self.ui:close(self) end
        if ev.key == "next" and self.page < self.pages then self.page = self.page + 1; self.ui:set_dirty() end
        if ev.key == "prev" and self.page > 1 then self.page = self.page - 1; self.ui:set_dirty() end
        return true
    end
    if ev.type ~= "tap" then
        if ev.type == "swipe" and (ev.dir == "left" or ev.dir == "right") then
            self.page = math.max(1, math.min(self.pages, self.page + (ev.dir == "left" and 1 or -1)))
            self.ui:set_dirty()
        end
        return true
    end
    if not inside(ev, self.rect) or (self.close_rect and inside(ev, self.close_rect)) then
        self.ui:close(self)
        return true
    end
    if self.pager_rect and inside(ev, self.pager_rect) then
        if ev.x < self.rect.w / 2 then self.page = math.max(1, self.page - 1) else self.page = math.min(self.pages, self.page + 1) end
        self.ui:set_dirty()
        return true
    end
    for _, row in ipairs(self.rows or {}) do
        if inside(ev, row) and row.enabled then
            local it = row.item
            if it.submenu then
                self.hidden = true
                self.ui:show(Menu.new({ title = resolve(it.text), items = resolve(it.submenu), parent = self }))
            else
                if not it.keep_open then
                    self.ui:close(self)
                    local p = self.parent
                    while p do self.ui:close(p); p = p.parent end
                else
                    self.ui:set_dirty()
                end
                if it.callback then it.callback() end
            end
            return true
        end
    end
    return true
end

------------------------------------------------------------------------------
-- ListView: full-screen paginated list (file browser, TOC, choosers).
-- items = { {text=, subtext=, callback=, bold=} }
------------------------------------------------------------------------------
local ListView = {}
ListView.__index = ListView
W.ListView = ListView

function ListView.new(opts)
    return setmetatable({ title = opts.title, items = opts.items or {}, page = 1,
        on_close = opts.on_close, closable = opts.closable ~= false, refresh_mode = "full", fullscreen = true,
        start_index = opts.start_index, icons = opts.icons }, ListView)
end

function ListView:set_items(items, title)
    self.items = items
    self.title = title or self.title
    self.page = 1
    if self.ui then self.ui:set_dirty("full") end
end

function ListView:draw(c)
    local t = W.theme(self.ui)
    c:fill_rect(0, 0, c.w, c.h, 255)
    title_bar(self, c, self.title)
    -- With icons (book covers) rows are taller and text moves right.
    local row_h = math.floor(t.row_h * (self.icons and 1.7 or 1.15))
    self.per_page = math.max(1, math.floor((c.h - 2 * t.bar_h) / row_h))
    self.pages = math.max(1, math.ceil(#self.items / self.per_page))
    if self.start_index then
        self.page = math.floor((self.start_index - 1) / self.per_page) + 1
        self.start_index = nil
    end
    self.page = math.min(self.page, self.pages)
    self.rows = {}
    local y = t.bar_h
    local first = (self.page - 1) * self.per_page + 1
    for i = first, math.min(#self.items, first + self.per_page - 1) do
        local it = self.items[i]
        local font = it.bold and t.bold or t.font
        local indent = (it.depth and (it.depth - 1) * t.pad * 2 or 0) + 2 * t.pad
        if self.icons then
            local ih = row_h - 2 * t.pad
            local iw = math.floor(ih * 0.68)
            if it.icon then
                local ok, err = pcall(it.icon, c, indent, y + t.pad, iw, ih)
                if not ok then require("tome.log").warn("icon draw failed:", err) end
            end
            indent = indent + iw + 2 * t.pad
        end
        local base = y + (row_h + font.ascent - font.descent) / 2
        if it.subtext then base = y + row_h * 0.45 end
        c:text(font, fit(font, it.text or "?", c.w - indent - 2 * t.pad), indent, base)
        if it.subtext then c:text(t.small, fit(t.small, it.subtext, c.w - indent - 2 * t.pad), indent, y + row_h * 0.82, 90) end
        if it.marked then c:fill_rect(0, y + t.pad, t.pad * 0.6, row_h - 2 * t.pad, 0) end
        c:fill_rect(t.pad, y + row_h - 1, c.w - 2 * t.pad, 1, 200)
        self.rows[#self.rows + 1] = { x = 0, y = y, w = c.w, h = row_h, item = it }
        y = y + row_h
    end
    if #self.items == 0 then
        c:text(t.font, "(empty)", 2 * t.pad, t.bar_h + row_h * 0.6, 120)
    end
    page_footer(self, c, self.page, self.pages)
end

function ListView:_turn(d)
    local p = math.max(1, math.min(self.pages or 1, self.page + d))
    if p ~= self.page then self.page = p; self.ui:set_dirty() end
end

function ListView:handle(ev)
    if ev.type == "key" then
        if ev.key == "next" or ev.key == "down" then self:_turn(1)
        elseif ev.key == "prev" or ev.key == "up" then self:_turn(-1)
        elseif ev.key == "back" and self.closable then self.ui:close(self) end
    elseif ev.type == "swipe" then
        if ev.dir == "left" or ev.dir == "up" then self:_turn(1) elseif ev.dir == "right" or ev.dir == "down" then self:_turn(-1) end
    elseif ev.type == "tap" then
        if self.close_rect and inside(ev, self.close_rect) then
            if self.closable then self.ui:close(self) end
        elseif self.prev_rect and inside(ev, self.prev_rect) then self:_turn(-1)
        elseif self.next_rect and inside(ev, self.next_rect) then self:_turn(1)
        else
            for _, row in ipairs(self.rows or {}) do
                if inside(ev, row) and row.item.callback then
                    row.item.callback(row.item)
                    break
                end
            end
        end
    elseif ev.type == "hold" then
        for _, row in ipairs(self.rows or {}) do
            if inside(ev, row) and row.item.hold_callback then row.item.hold_callback(row.item); break end
        end
    end
    return true
end

------------------------------------------------------------------------------
-- TextViewer: full-screen paginated reading of plain/markdown-ish text.
-- Lines starting with "# "/"## " become headings, "- "/"* " list items.
------------------------------------------------------------------------------
local TextViewer = {}
TextViewer.__index = TextViewer
W.TextViewer = TextViewer

function TextViewer.new(opts)
    return setmetatable({ title = opts.title, text = opts.text or "", page = 1, refresh_mode = "full", fullscreen = true,
        close_refresh = "full", font_size = opts.font_size, buttons = opts.buttons }, TextViewer)
end

local function strip_md(s)
    return (s:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1"))
end

--- Convert text into blocks for Layout (bold via **x**, italics via *x*).
function TextViewer.to_blocks(text)
    local blocks = {}
    local function runs_of(s)
        local runs = {}
        local pos = 1
        while pos <= #s do
            local a, b, inner = s:find("%*%*(.-)%*%*", pos)
            if not a then runs[#runs + 1] = { text = s:sub(pos), style = "r"; }; break end
            if a > pos then runs[#runs + 1] = { text = s:sub(pos, a - 1), style = "r" } end
            runs[#runs + 1] = { text = inner, style = "b" }
            pos = b + 1
        end
        for _, r in ipairs(runs) do r.text = r.text:gsub("%*(%S.-)%*", "%1") end
        return runs
    end
    local para = {}
    local function flush()
        if #para > 0 then
            local s = table.concat(para, " ")
            local runs = runs_of(s)
            local parts = {}
            for i, r in ipairs(runs) do parts[i] = r.text end
            blocks[#blocks + 1] = { kind = "p", runs = runs, text = table.concat(parts) }
            para = {}
        end
    end
    for line in (text .. "\n"):gmatch("(.-)\r?\n") do
        local h, rest = line:match("^(#+)%s+(.*)$")
        local li = line:match("^%s*[-*\226]%s+(.*)$")
        if h then
            flush()
            rest = strip_md(rest)
            blocks[#blocks + 1] = { kind = "h", level = math.min(#h + 1, 4), runs = { { text = rest, style = "b" } }, text = rest }
        elseif li and not line:match("^%s*%*%*") then
            flush()
            local runs = runs_of("\226\128\162 " .. li)
            local parts = {}
            for i, r in ipairs(runs) do parts[i] = r.text end
            blocks[#blocks + 1] = { kind = "li", runs = runs, text = table.concat(parts) }
        elseif line:match("^%s*$") then
            flush()
        else
            para[#para + 1] = line
        end
    end
    flush()
    for _, b in ipairs(blocks) do b.text = b.text or "" end
    return blocks
end

function TextViewer:on_resize()
    self.pages_cache = nil
end

function TextViewer:set_text(text)
    self.text = text
    self.pages_cache = nil
    self.page = 1
    if self.ui then self.ui:set_dirty("full") end
end

function TextViewer:_paginate(c)
    if self.pages_cache then return self.pages_cache end
    local t = W.theme(self.ui)
    local layout = Layout.new({
        width = c.w, height = c.h, margin_x = t.pad * 3, margin_top = t.bar_h + t.pad,
        margin_bottom = t.bar_h + t.pad, font_size = self.font_size or math.floor(self.ui.device.dpi * 0.11),
        line_spacing = 1.2, justify = false, indent = false, paragraph_gap = 0.6,
    })
    self.layout = layout
    self.pages_cache = layout:paginate({ blocks = TextViewer.to_blocks(self.text) })
    return self.pages_cache
end

function TextViewer:draw(c)
    local pages = self:_paginate(c)
    c:fill_rect(0, 0, c.w, c.h, 255)
    title_bar(self, c, self.title)
    self.page = math.min(self.page, #pages)
    self.layout:draw(c, pages[self.page])
    page_footer(self, c, self.page, #pages)
end

function TextViewer:handle(ev)
    local n = self.pages_cache and #self.pages_cache or 1
    local function turn(d)
        local p = math.max(1, math.min(n, self.page + d))
        if p ~= self.page then self.page = p; self.ui:set_dirty() end
    end
    if ev.type == "key" then
        if ev.key == "next" or ev.key == "down" then turn(1)
        elseif ev.key == "prev" or ev.key == "up" then turn(-1)
        elseif ev.key == "back" or ev.key == "menu" then self.ui:close(self) end
    elseif ev.type == "swipe" then
        if ev.dir == "left" then turn(1) elseif ev.dir == "right" then turn(-1) end
    elseif ev.type == "tap" then
        if self.close_rect and inside(ev, self.close_rect) then self.ui:close(self)
        elseif ev.x < self.ui.device.width / 3 then turn(-1)
        else turn(1) end
    end
    return true
end

------------------------------------------------------------------------------
-- Message / Progress / Confirm: centered dialog box.
------------------------------------------------------------------------------
local Dialog = {}
Dialog.__index = Dialog
W.Dialog = Dialog

--- opts: text, title, buttons = { {text=, callback=} }, timeout_ms, dismissable
function Dialog.new(opts)
    return setmetatable({ text = opts.text or "", title = opts.title, buttons = opts.buttons or {},
        dismissable = opts.dismissable ~= false, timeout_ms = opts.timeout_ms }, Dialog)
end

function Dialog:on_show()
    if self.timeout_ms then
        self.timer = self.ui:schedule(self.timeout_ms, function() self.ui:close(self) end)
    end
end

function Dialog:on_close()
    if self.timer then self.ui:cancel_timer(self.timer) end
end

function Dialog:set_text(text)
    if text ~= self.text then
        self.text = text
        if self.ui then self.ui:set_dirty() end
    end
end

function Dialog:draw(c)
    local t = W.theme(self.ui)
    local w = math.floor(c.w * 0.82)
    local inner = w - 4 * t.pad
    local lines = wrap(t.font, self.text, inner)
    local lh = t.font.line_height
    local h = 2 * t.pad + #lines * lh + (self.title and t.title.line_height + t.pad or 0)
        + (#self.buttons > 0 and t.row_h + 2 * t.pad or t.pad)
    local x, y = math.floor((c.w - w) / 2), math.floor((c.h - h) / 2)
    self.rect = { x = x, y = y, w = w, h = h }
    c:fill_rect(x - t.border, y - t.border, w + 2 * t.border, h + 2 * t.border, 255)
    c:rect(x, y, w, h, 0, t.border)
    local cy = y + t.pad
    if self.title then
        cy = cy + t.title.ascent
        c:text(t.title, fit(t.title, self.title, inner), x + 2 * t.pad, cy)
        cy = cy + t.title.descent + t.pad
    end
    for _, l in ipairs(lines) do
        c:text(t.font, l, x + 2 * t.pad, cy + t.font.ascent)
        cy = cy + lh
    end
    self.button_rects = {}
    if #self.buttons > 0 then
        local bw = math.floor((w - (#self.buttons + 1) * t.pad * 2) / #self.buttons)
        local by = y + h - t.pad * 2 - t.row_h
        for i, b in ipairs(self.buttons) do
            local r = { x = x + 2 * t.pad + (i - 1) * (bw + 2 * t.pad), y = by, w = bw, h = t.row_h }
            draw_button(c, r, b.text, t.bold, b.primary, t.border)
            self.button_rects[i] = r
        end
    end
end

function Dialog:handle(ev)
    if ev.type == "tap" then
        for i, r in ipairs(self.button_rects or {}) do
            if inside(ev, r) then
                local b = self.buttons[i]
                if not b.keep_open then self.ui:close(self) end
                if b.callback then b.callback() end
                return true
            end
        end
        -- tap outside closes; with no buttons, any tap closes
        if self.dismissable and (#self.buttons == 0 or not inside(ev, self.rect)) then self.ui:close(self) end
    elseif ev.type == "key" and ev.key == "back" and self.dismissable then
        self.ui:close(self)
    end
    return true
end

return W
