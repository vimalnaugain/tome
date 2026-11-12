--[[
Library screen: every EPUB on the Kindle as a grid of covers, like the
Kindle's own library. Filter (All / Reading / Finished / New), sort (Recent /
Title / Author), page with taps or swipes. Tap a book to open it; hold for
details and "mark as finished".
--]]
local Cover = require("tome.ui.cover")
local Font = require("tome.font")
local W = require("tome.ui.widgets")

local LibraryView = {}
LibraryView.__index = LibraryView

local FILTERS = { { "All", "all" }, { "Reading", "reading" }, { "Finished", "finished" }, { "New", "new" } }
local SORTS = { { "Recent", "recent" }, { "Title", "title" }, { "Author", "author" } }

function LibraryView.new(app)
    local self = setmetatable({ app = app, fullscreen = true, refresh_mode = "full", page = 1,
        filter = app.settings.library_filter or "all", sort = app.settings.library_sort or "recent", hits = {} }, LibraryView)
    self.scanned = false
    return self
end

function LibraryView:on_show()
    self:reload(true)
end

function LibraryView:on_close()
    if self.cover_task then self.cover_task.cancel() end
end

--- Rescan the device (rescan=true) and rebuild the visible list.
function LibraryView:reload(rescan)
    local app = self.app
    if rescan then app.library:scan() end
    self.books = app.library:books(self.sort, self.filter)
    self.total = app.library:count()
    if self.ui then self.ui:set_dirty("full") end
    -- decode covers in the background, current order first
    if self.cover_task then self.cover_task.cancel() end
    local pending = {}
    for _, b in ipairs(self.books) do
        if not app.covers:has_master(b.id) and not app.covers:has_none(b.id) then pending[#pending + 1] = b end
    end
    if #pending > 0 then
        local fresh = 0
        self.cover_task = app.covers:prepare_all(pending, function()
            fresh = fresh + 1
            if self.ui and self.ui:top() == self then self.ui:set_dirty("partial") end
        end, function()
            -- titles from new books are known now
            if fresh > 0 then
                self.books = app.library:books(self.sort, self.filter)
                if self.ui and self.ui:top() == self then self.ui:set_dirty("partial") end
            end
        end)
    end
end

function LibraryView:_set(key, value)
    self[key] = value
    self.app.settings["library_" .. key] = value
    self.app:save_settings()
    self.page = 1
    self:reload(false)
end

local function center(c, font, s, x, y, w, h, color)
    c:text(font, s, x + (w - font:width(s)) / 2, y + (h + font.ascent - font.descent) / 2, color)
end

function LibraryView:draw(c)
    local t = W.theme(self.ui)
    local app = self.app
    local pad = t.pad
    self.hits = {}
    c:fill_rect(0, 0, c.w, c.h, 255)

    -- title bar
    local base = math.floor((t.bar_h + t.title.ascent - t.title.descent) / 2)
    c:text(t.title, "Library", pad * 2, base)
    local count = string.format("%d book%s", self.total or 0, self.total == 1 and "" or "s")
    c:text(t.small, count, pad * 2 + t.title:width("Library") + pad * 2, base, 110)
    center(c, t.title, "\195\151", c.w - t.bar_h, 0, t.bar_h, t.bar_h, 0)
    self.hits[#self.hits + 1] = { x = c.w - t.bar_h, y = 0, w = t.bar_h, h = t.bar_h, fn = function() self.ui:close(self) end }
    c:fill_rect(0, t.bar_h - t.border, c.w, t.border, 0)

    -- toolbar: filters (left) and sort (right)
    local ty, th = t.bar_h, math.floor(t.row_h * 0.85)
    local fx = pad * 2
    for _, f in ipairs(FILTERS) do
        local on = self.filter == f[2]
        local w = t.font:width(f[1]) + pad * 3
        if on then c:fill_rect(fx, ty + th - t.border * 3 - pad / 2, w, t.border * 3, 0) end
        center(c, on and t.bold or t.font, f[1], fx, ty, w, th, on and 0 or 100)
        self.hits[#self.hits + 1] = { x = fx, y = ty, w = w, h = th, fn = function() self:_set("filter", f[2]) end }
        fx = fx + w
    end
    local sort_label
    for i, s in ipairs(SORTS) do
        if s[2] == self.sort then sort_label = s[1] .. "  \226\150\190"; self.next_sort = SORTS[i % #SORTS + 1][2] end
    end
    local sw = t.font:width(sort_label) + pad * 2
    center(c, t.font, sort_label, c.w - pad * 2 - sw, ty, sw, th, 0)
    self.hits[#self.hits + 1] = { x = c.w - pad * 2 - sw, y = ty, w = sw + pad * 2, h = th,
        fn = function() self:_set("sort", self.next_sort) end }
    c:fill_rect(pad, ty + th, c.w - 2 * pad, 1, 200)

    -- grid
    local landscape = c.w > c.h
    local cols = landscape and 6 or 4
    local gap = math.floor(pad * 1.2)
    local cell_w = math.floor((c.w - gap * (cols + 1)) / cols)
    local cover_h = math.floor(cell_w * 1.45)
    local cap_font = t.small
    local caption_h = cap_font.line_height * 2 + pad
    local cell_h = cover_h + caption_h + gap
    local top = ty + th + gap
    local footer_h = t.bar_h
    local rows = math.max(1, math.floor((c.h - top - footer_h) / cell_h))
    local per_page = rows * cols
    local books = self.books or {}
    self.pages = math.max(1, math.ceil(#books / per_page))
    self.page = math.min(self.page, self.pages)

    if #books == 0 then
        local msg = self.total == 0
            and "No books yet. Copy EPUB files to your Kindle over USB; any folder works."
            or "No books in this view."
        local y = top + t.row_h
        for _, l in ipairs(W.wrap(t.font, msg, c.w - 4 * pad)) do
            c:text(t.font, l, pad * 2, y, 90)
            y = y + t.font.line_height
        end
    end

    local first = (self.page - 1) * per_page + 1
    for i = first, math.min(#books, first + per_page - 1) do
        local k = i - first
        local col, row = k % cols, math.floor(k / cols)
        local x = gap + col * (cell_w + gap)
        local y = top + row * cell_h
        local b = books[i]
        Cover.draw(app, c, x, y, cell_w, cover_h, b, "fill")
        -- status badge on the cover
        if b.status == "finished" then
            local s = "\226\156\147 Read"
            local bw = cap_font:width(s) + pad
            c:fill_rect(x + cell_w - bw - pad / 2, y + pad / 2, bw, cap_font.line_height, 0)
            c:text(cap_font, s, x + cell_w - bw - pad / 2 + pad / 2, y + pad / 2 + cap_font.ascent, 255)
        elseif b.status == "new" then
            local s = "NEW"
            local bw = cap_font:width(s) + pad
            c:fill_rect(x + pad / 2, y + pad / 2, bw, cap_font.line_height, 255)
            c:rect(x + pad / 2, y + pad / 2, bw, cap_font.line_height, 0, 1)
            c:text(cap_font, s, x + pad / 2 + pad / 2, y + pad / 2 + cap_font.ascent, 0)
        end
        -- progress bar under the cover
        local cy = y + cover_h + math.floor(pad / 2)
        if b.status == "reading" then
            c:fill_rect(x, cy, cell_w, t.border * 2, 215)
            c:fill_rect(x, cy, math.floor(cell_w * (b.percent or 0)), t.border * 2, 0)
        end
        cy = cy + t.border * 2 + math.floor(pad / 2)
        -- one line: title, plus % for books in progress
        local bold = Font.get("sans", "b", cap_font.size)
        local pct = b.status == "reading" and string.format("  %.0f%%", (b.percent or 0) * 100) or ""
        local title = W.fit(bold, b.title or "?", cell_w - cap_font:width(pct))
        local ex = c:text(bold, title, x, cy + bold.ascent)
        if pct ~= "" then c:text(cap_font, pct, ex, cy + bold.ascent, 100) end
        self.hits[#self.hits + 1] = { x = x, y = y, w = cell_w, h = cell_h - gap, book = b }
    end

    -- footer
    local fy = c.h - footer_h
    c:fill_rect(0, fy, c.w, t.border, 0)
    local label = string.format("%d / %d", self.page, self.pages)
    center(c, t.font, label, 0, fy, c.w, footer_h, 0)
    if self.page > 1 then center(c, t.title, "\226\151\128", 0, fy, c.w / 4, footer_h, 0) end
    if self.page < self.pages then center(c, t.title, "\226\150\182", c.w * 3 / 4, fy, c.w / 4, footer_h, 0) end
    self.hits[#self.hits + 1] = { x = 0, y = fy, w = c.w / 3, h = footer_h, fn = function() self:_turn(-1) end }
    self.hits[#self.hits + 1] = { x = c.w * 2 / 3, y = fy, w = c.w / 3, h = footer_h, fn = function() self:_turn(1) end }
end

function LibraryView:_turn(d)
    local p = math.max(1, math.min(self.pages or 1, self.page + d))
    if p ~= self.page then self.page = p; self.ui:set_dirty("partial") end
end

function LibraryView:_details(b)
    local app = self.app
    local lines = { b.title or "?" }
    if b.authors and #b.authors > 0 then lines[#lines + 1] = table.concat(b.authors, ", ") end
    if b.status == "reading" then lines[#lines + 1] = string.format("%.0f%% read", (b.percent or 0) * 100)
    elseif b.status == "finished" then lines[#lines + 1] = "Finished" end
    lines[#lines + 1] = b.path:gsub("^/mnt/us/", "")
    app.ui:show(W.Dialog.new({ text = table.concat(lines, "\n"), buttons = {
        { text = b.finished and "Mark unread" or "Mark finished", callback = function()
            app.stats:set_finished(b.id, not b.finished)
            self:reload(false)
        end },
        { text = "Open", primary = true, callback = function() app:open_book(b.path) end },
    } }))
end

function LibraryView:handle(ev)
    if ev.type == "key" then
        if ev.key == "next" or ev.key == "down" then self:_turn(1)
        elseif ev.key == "prev" or ev.key == "up" then self:_turn(-1)
        elseif ev.key == "back" or ev.key == "home" then self.ui:close(self) end
    elseif ev.type == "swipe" then
        if ev.dir == "left" or ev.dir == "up" then self:_turn(1) elseif ev.dir == "right" or ev.dir == "down" then self:_turn(-1) end
    elseif ev.type == "tap" or ev.type == "hold" then
        for i = #self.hits, 1, -1 do
            local h = self.hits[i]
            if W.inside(ev, h) then
                if h.book then
                    if ev.type == "hold" then self:_details(h.book) else self.app:open_book(h.book.path) end
                elseif h.fn and ev.type == "tap" then
                    h.fn()
                end
                return true
            end
        end
    end
    return true
end

return LibraryView
