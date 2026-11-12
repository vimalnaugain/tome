--[[
Home screen: the book you're reading (with progress and time left), other
books in progress, a few reading stats, and the way into the library.
--]]
local Font = require("tome.font")
local Stats = require("tome.stats")
local Cover = require("tome.ui.cover")
local W = require("tome.ui.widgets")
local util = require("tome.util")

local Home = {}
Home.__index = Home

function Home.new(app)
    local self = setmetatable({ app = app, fullscreen = true, refresh_mode = "full", targets = {} }, Home)
    self:refresh()
    return self
end

--- Reload books and stats (after closing a book, finishing one, etc.).
function Home:refresh()
    local app = self.app
    self.reading = {}
    for _, b in ipairs(app:recent_books()) do
        if not app.stats:is_finished(b.id or "") and (b.percent or 0) < 0.995 then
            self.reading[#self.reading + 1] = b
        end
    end
    local p = io.popen("find " .. util.shell_quote(app.books_dir) .. " -iname '*.epub' 2>/dev/null | wc -l")
    self.library_count = p and tonumber(p:read("*a"):match("%d+")) or 0
    if p then p:close() end
    if self.ui then self.ui:set_dirty("full") end
    -- decode missing covers in the background, redrawing as each is ready
    if #self.reading > 0 then
        if self.cover_task then self.cover_task.cancel() end
        self.cover_task = app.covers:prepare_all(self.reading, function()
            if self.ui and self.ui:top() == self then self.ui:set_dirty("partial") end
        end)
    end
end

function Home:on_show() self:refresh() end

local function progress_bar(c, x, y, w, frac, t)
    local h = math.max(6, t.border * 3)
    c:fill_rect(x, y, w, h, 220)
    c:fill_rect(x, y, math.floor(w * math.max(0, math.min(1, frac))), h, 0)
    return h
end

local function authors_of(b)
    return (b.authors and #b.authors > 0) and table.concat(b.authors, ", ") or ""
end

function Home:draw(c)
    local t = W.theme(self.ui)
    local app = self.app
    local w, h = c.w, c.h
    local pad = t.pad
    local mx = pad * 2
    self.targets = {}
    c:fill_rect(0, 0, w, h, 255)

    -- Header
    local base = math.floor((t.bar_h + t.title.ascent - t.title.descent) / 2)
    c:text(t.title, "Tome", mx, base)
    local date = os.date("%A, %d %B"):gsub(" 0", " ")
    c:text(t.small, date, w - mx - t.small:width(date), base, 90)
    c:fill_rect(0, t.bar_h - t.border, w, t.border, 0)

    local function label(text, y)
        c:text(t.small, text:upper(), mx, y + t.small.ascent, 110)
        return y + t.small.line_height + pad
    end

    -- Bottom rows (anchored), so the middle can adapt to the space left.
    local row_h = t.row_h
    local bottom_y = h - 2 * row_h
    c:fill_rect(0, bottom_y, w, t.border, 0)
    local lib_label = string.format("Library  \194\183  %d book%s", self.library_count, self.library_count == 1 and "" or "s")
    c:text(t.font, lib_label, mx, bottom_y + (row_h + t.font.ascent) / 2)
    c:text(t.bold, "\226\134\146", w - mx - t.bold:width("\226\134\146"), bottom_y + (row_h + t.bold.ascent) / 2)
    self.targets[#self.targets + 1] = { x = 0, y = bottom_y, w = w, h = row_h, action = function() app:show_library() end }
    c:fill_rect(mx, bottom_y + row_h, w - 2 * mx, 1, 200)
    c:text(t.font, "Exit Tome", mx, bottom_y + row_h + (row_h + t.font.ascent) / 2, 60)
    self.targets[#self.targets + 1] = { x = 0, y = bottom_y + row_h, w = w, h = row_h, action = function() app:confirm_quit() end }

    -- Stats block, directly above the bottom rows.
    local stats = app.stats
    local year = stats:year()
    local big = Font.get("sans", "b", math.floor(app.device.dpi * 0.17))
    local stats_h = t.small.line_height + pad + big.line_height + t.small.line_height + pad * 2
    local sy = bottom_y - stats_h
    local y2 = label("Your reading", sy)
    local tiles = {
        { tostring(year.finished), "finished in " .. os.date("%Y"),
            function() self:show_finished() end },
        { Stats.format_duration(year.seconds, true), "read this year" },
        { tostring(stats:streak_days()), stats:streak_days() == 1 and "day in a row" or "days in a row" },
    }
    local tw = math.floor((w - 2 * mx) / #tiles)
    for i, tile in ipairs(tiles) do
        local tx = mx + (i - 1) * tw
        c:text(big, tile[1], tx, y2 + big.ascent)
        c:text(t.small, W.fit(t.small, tile[2], tw - pad), tx, y2 + big.line_height + t.small.ascent, 90)
        if tile[3] then
            self.targets[#self.targets + 1] = { x = tx, y = sy, w = tw, h = stats_h, action = tile[3] }
        end
    end

    -- Currently reading
    local y = t.bar_h + pad * 2
    y = label("Currently reading", y)
    local cur = self.reading[1]
    if not cur then
        local lines = W.wrap(t.font, "Nothing in progress. Open a book from your library to start.", w - 2 * mx)
        for _, l in ipairs(lines) do
            c:text(t.font, l, mx, y + t.font.ascent, 80)
            y = y + t.font.line_height
        end
        return
    end
    local avail = sy - y - pad * 2
    local cover_w = math.floor(math.min(w * 0.3, avail / 1.5))
    local cover_h = math.floor(cover_w * 1.5)
    Cover.draw(app, c, mx, y, cover_w, cover_h, cur, "fill")
    local tx = mx + cover_w + pad * 2
    local text_w = w - tx - mx
    local tf = Font.get("serif", "b", math.floor(app.device.dpi * 0.13))
    local ty = y
    for i, l in ipairs(W.wrap(tf, cur.title or "?", text_w)) do
        if i > 3 then break end
        c:text(tf, l, tx, ty + tf.ascent)
        ty = ty + tf.line_height
    end
    local author = authors_of(cur)
    if author ~= "" then
        c:text(t.font, W.fit(t.font, author, text_w), tx, ty + t.font.ascent, 70)
        ty = ty + t.font.line_height
    end
    ty = ty + pad
    ty = ty + progress_bar(c, tx, ty, text_w, cur.percent or 0, t) + pad
    local info = string.format("%.0f%%", (cur.percent or 0) * 100)
    if cur.seconds_left then info = info .. "  \194\183  " .. Stats.format_duration(cur.seconds_left, true) .. " left" end
    c:text(t.font, info, tx, ty + t.font.ascent)
    ty = ty + t.font.line_height
    if cur.chapter_title then
        c:text(t.small, W.fit(t.small, cur.chapter_title, text_w), tx, ty + t.small.ascent, 90)
        ty = ty + t.small.line_height
    end
    -- "Continue reading" button
    local by = math.max(ty + pad, y + cover_h - t.row_h)
    local btn = { x = tx, y = by, w = math.min(text_w, math.floor(w * 0.45)), h = t.row_h }
    W.draw_button(c, btn, "Continue reading", t.bold, true, t.border)
    local open_cur = function() app:open_book(cur.path) end
    self.targets[#self.targets + 1] = { x = 0, y = y, w = w, h = math.max(cover_h, by + t.row_h - y), action = open_cur }
    y = math.max(y + cover_h, by + t.row_h) + pad * 3

    -- Other books in progress, as many as fit.
    if #self.reading > 1 and y + t.small.line_height + pad + row_h <= sy then
        y = label("Also reading", y)
        for i = 2, #self.reading do
            if y + row_h > sy - pad then break end
            local b = self.reading[i]
            local pct = string.format("%.0f%%", (b.percent or 0) * 100)
            c:text(t.font, W.fit(t.font, b.title or "?", w - 2 * mx - t.font:width(pct) - pad * 2), mx, y + (row_h + t.font.ascent) / 2 - pad)
            c:text(t.font, pct, w - mx - t.font:width(pct), y + (row_h + t.font.ascent) / 2 - pad, 80)
            progress_bar(c, mx, y + row_h - pad * 2, w - 2 * mx, b.percent or 0, t)
            self.targets[#self.targets + 1] = { x = 0, y = y, w = w, h = row_h, action = function() app:open_book(b.path) end }
            y = y + row_h
        end
    end
end

function Home:show_finished()
    local items = {}
    local list = {}
    for id, b in pairs(self.app.stats.data.books) do
        if b.finished then list[#list + 1] = { id = id, b = b } end
    end
    table.sort(list, function(a, b) return a.b.finished > b.b.finished end)
    for _, e in ipairs(list) do
        items[#items + 1] = { text = e.b.title or "?", subtext = "Finished " .. os.date("%d %B %Y", e.b.finished):gsub("^0", ""),
            callback = function() if e.b.path and util.file_exists(e.b.path) then self.app:open_book(e.b.path) end end }
    end
    self.ui:show(W.ListView.new({ title = "Finished books", items = items }))
end

function Home:handle(ev)
    if ev.type == "tap" then
        for i = #self.targets, 1, -1 do
            local r = self.targets[i]
            if W.inside(ev, r) then r.action(); return true end
        end
    elseif ev.type == "key" then
        if ev.key == "menu" then self.app:show_main_menu()
        elseif ev.key == "select" and self.reading[1] then self.app:open_book(self.reading[1].path) end
    end
    return true
end

return Home
