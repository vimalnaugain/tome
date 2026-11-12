--[[
Reader view: one EPUB page at a time, page turns, the reader menu, per-book
state, reading-time tracking and the status bar. It is also the object
plugins receive as `reader` -- see docs/PLUGIN_API.md for the public part.
--]]
local Epub = require("tome.epub")
local Layout = require("tome.layout")
local Font = require("tome.font")
local Stats = require("tome.stats")
local Rotation = require("tome.device.rotation")
local UI = require("tome.ui.manager")
local W = require("tome.ui.widgets")
local util = require("tome.util")
local log = require("tome.log")

local Reader = {}
Reader.__index = Reader

local FONT_SIZES = { 22, 26, 30, 34, 40, 46, 54 }
local FACES = { { "serif", "Caladea" }, { "charter", "Charter" }, { "sans", "Carlito (sans)" } }
-- horizontal / vertical margins in inches
local MARGINS = { narrow = { 0.12, 0.12 }, medium = { 0.22, 0.18 }, wide = { 0.36, 0.26 } }
local MARGIN_ORDER = { "narrow", "medium", "wide" }
local FOOTER_MODES = 4

function Reader.open(app, path)
    local doc, err = Epub.open(path)
    if not doc then return nil, err end
    local self = setmetatable({ app = app, doc = doc, path = path, pages = {}, refresh_mode = "full",
        fullscreen = true }, Reader)
    self.book_id = util.file_fingerprint(path)
    self.state_path = app.data_dir .. "/books/" .. self.book_id .. ".lua"
    local defaults = app.settings.reader or {}
    local st = util.load_table(self.state_path) or {}
    self.state = st
    st.font_size = st.font_size or defaults.font_size or (app.device.dpi >= 250 and 34 or 22)
    st.line_spacing = st.line_spacing or defaults.line_spacing or 1.3
    st.face = st.face or defaults.face or "serif"
    st.margins = st.margins or defaults.margins or "medium"
    st.footer_mode = st.footer_mode or 1
    st.position = st.position or { chapter = 1, block = 1, offset = 0 }
    -- chapter text lengths, filled in the background (for % and time left)
    if not st.chapter_chars or #st.chapter_chars > #doc.chapters then st.chapter_chars = {} end
    self.previous_read = st.last_read -- before this session
    st.title, st.authors, st.path = doc.title, doc.authors, path
    self.stats = app.stats
    self.stats:book(self.book_id, { title = doc.title, authors = doc.authors, path = path })
    self.page_turns = 0
    self:_relayout()
    self:_goto(st.position)
    return self
end

------------------------------------------------------------------------------
-- Public API for plugins
------------------------------------------------------------------------------

--- { id, title, authors = {...}, language, path, chapters = n }
function Reader:book_info()
    return { id = self.book_id, title = self.doc.title, authors = self.doc.authors,
        language = self.doc.language, path = self.path, chapters = #self.doc.chapters }
end

--- Position of the first character on the current page:
-- { chapter, block, offset, percent, chapter_title, page, pages, chapter_seconds_left, book_seconds_left }
function Reader:position()
    local p = self:_page()
    local pos = { chapter = self.chapter, block = p.first.block, offset = p.first.offset }
    pos.percent = math.floor(self:_fraction(pos) * 1000 + 0.5) / 10
    pos.chapter_title = self.doc:chapter_title(self.chapter)
    pos.page, pos.pages = self.page, #self.pages[self.chapter]
    pos.chapter_seconds_left, pos.book_seconds_left = self:time_left()
    return pos
end

--- Position just past the last character on the current page.
function Reader:page_end()
    local p = self:_page()
    return { chapter = self.chapter, block = p.last.block, offset = p.last.offset }
end

--- { {index, title}, ... } for every spine item.
function Reader:chapters()
    local out = {}
    for i = 1, #self.doc.chapters do out[i] = { index = i, title = self.doc:chapter_title(i) } end
    return out
end

--- Plain text between positions (nil = book start / book end).
function Reader:text_range(from, to) return self.doc:text_range(from, to) end

--- Whole text of chapter i, or up to position `upto` if it is in that chapter.
function Reader:chapter_text(i, upto)
    local to = { chapter = i, block = math.huge, offset = 0 }
    if upto and upto.chapter == i then to = upto end
    return self.doc:text_range({ chapter = i, block = 1, offset = 0 }, to)
end

--- Everything the reader has seen, up to the end of the current page,
-- limited to the last max_chars characters (whole paragraphs).
function Reader:text_read_so_far(max_chars)
    local to = self:page_end()
    if not max_chars then return self.doc:text_range(nil, to) end
    local parts, total = {}, 0
    for ci = to.chapter, 1, -1 do
        local t = self:chapter_text(ci, to)
        table.insert(parts, 1, t)
        total = total + #t
        if total >= max_chars then break end
    end
    local text = table.concat(parts, "\n\n")
    if #text > max_chars then
        text = text:sub(#text - max_chars + 1)
        text = text:gsub("^[^\n]*\n+", "", 1) -- start at a paragraph boundary
    end
    return text
end

--- os.time() of the previous reading session, or nil for a new book.
function Reader:last_read_time() return self.previous_read end

--- Seconds left in the current chapter and in the book at the reader's pace.
function Reader:time_left()
    local cpm = self.stats:chars_per_minute()
    local done = self.doc:chars_into_chapter(self:page_end())
    local ch_left = math.max(0, self:_chapter_len(self.chapter) - done)
    local book_left = ch_left
    for i = self.chapter + 1, #self.doc.chapters do book_left = book_left + self:_chapter_len(i) end
    return ch_left / cpm * 60, book_left / cpm * 60
end

--- Jump to a position table {chapter, block, offset}.
function Reader:go_to(pos)
    self:_goto(pos)
    self:_after_move(false)
end

------------------------------------------------------------------------------
-- Progress: chapter lengths in characters
------------------------------------------------------------------------------

--- Exact length if indexed, otherwise estimated from the file size.
function Reader:_chapter_len(i)
    local known = self.state.chapter_chars[i]
    if known then return known end
    local c = self.doc.cache[i]
    if c then
        self.state.chapter_chars[i] = c.length
        return c.length
    end
    -- chars per byte from what we already know (HTML markup ~ 40%)
    local kc, kb = 0, 0
    for j, n in pairs(self.state.chapter_chars) do
        kc, kb = kc + n, kb + self.doc.chapters[j].size
    end
    local ratio = kb > 0 and kc / kb or 0.6
    return self.doc.chapters[i].size * ratio
end

function Reader:_fraction(pos)
    local before, total = 0, 0
    for i = 1, #self.doc.chapters do
        local n = self:_chapter_len(i)
        if i < pos.chapter then before = before + n end
        total = total + n
    end
    if total <= 0 then return 0 end
    return math.min(1, (before + self.doc:chars_into_chapter(pos)) / total)
end

--- Measure every chapter once, in the background, a little at a time.
function Reader:_start_indexing()
    local missing = false
    for i = 1, #self.doc.chapters do
        if not self.state.chapter_chars[i] then missing = true; break end
    end
    if not missing then return end
    local dev = self.app.device
    self.index_task = self.app:run_task(function()
        for i = 1, #self.doc.chapters do
            if not self.state.chapter_chars[i] then
                local t0 = dev:monotonic_ms()
                local cached = self.doc.cache[i] ~= nil
                self.state.chapter_chars[i] = self.doc:chapter(i).length
                if not cached and math.abs(i - self.chapter) > 1 then self.doc.cache[i] = nil end
                -- yield so page turns stay instant
                if dev:monotonic_ms() - t0 > 30 or i % 4 == 0 then
                    if not UI.await(function() return true end) then return end
                end
            end
        end
        util.save_table(self.state_path, self.state)
        self.index_task = nil
        self.ui:set_dirty("partial") -- footer numbers just got exact
    end)
end

------------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------------

function Reader:_relayout()
    local d = self.app.device
    local dpi = d.dpi
    local m = MARGINS[self.state.margins] or MARGINS.medium
    self.footer_h = math.floor(dpi * 0.3)
    self.margin_x = math.floor(dpi * m[1])
    self.layout = Layout.new({
        width = d.width, height = d.height, face = self.state.face,
        margin_x = self.margin_x, margin_top = math.floor(dpi * m[2]),
        margin_bottom = self.footer_h + math.floor(dpi * 0.04),
        font_size = self.state.font_size, line_spacing = self.state.line_spacing,
        justify = (self.app.settings.reader or {}).justify ~= false,
    })
    self.footer_font = Font.get("sans", "r", math.floor(dpi * 0.075))
    self.pages = {}
end

function Reader:on_show()
    self.last_turn_ms = self.app.device:monotonic_ms()
    self:_start_indexing()
end

function Reader:on_resize()
    local pos = self:position()
    self:_relayout()
    self:_goto(pos)
end

function Reader:_chapter_pages(i)
    local p = self.pages[i]
    if not p then
        local t0 = self.app.device:monotonic_ms()
        p = self.layout:paginate(self.doc:chapter(i))
        self.pages[i] = p
        log.debug(string.format("paginated chapter %d: %d pages in %d ms", i, #p, self.app.device:monotonic_ms() - t0))
        -- Bound memory: keep only nearby chapters' parsed text and layout.
        local keep = { [i] = true, [i - 1] = true, [i + 1] = true }
        for k in pairs(self.pages) do if not keep[k] then self.pages[k] = nil end end
        self.doc:trim_cache(keep)
    end
    return p
end

function Reader:_page() return self:_chapter_pages(self.chapter)[self.page] end

function Reader:_goto(pos)
    local n = #self.doc.chapters
    self.chapter = math.max(1, math.min(n, pos.chapter or 1))
    local pages = self:_chapter_pages(self.chapter)
    if pos.page == "last" then
        self.page = #pages
    else
        self.page = Layout.find_page(pages, pos.block or 1, pos.offset or 0)
    end
end

function Reader:_save()
    local p = self:_page()
    local st = self.state
    st.position = { chapter = self.chapter, block = p.first.block, offset = p.first.offset }
    st.percent = self:_fraction(st.position)
    st.chapter_title = self.doc:chapter_title(self.chapter)
    local _, left = self:time_left()
    st.seconds_left = left
    st.last_read = os.time()
    util.save_table(self.state_path, st)
end

--- Called after every move. `chars_read` is the text of the page just left
-- when moving forward one page (for reading-speed learning).
function Reader:_after_move(chars_read)
    local now = self.app.device:monotonic_ms()
    if self.last_turn_ms and not self.ui.sleeping then
        self.stats:record(self.book_id, (now - self.last_turn_ms) / 1000, chars_read or nil)
    end
    self.last_turn_ms = now
    self:_save()
    self.page_turns = self.page_turns + 1
    self.ui:set_dirty("partial")
    self.app:broadcast("PageChanged", self, self:position())
end

function Reader:next_page()
    local pages = self:_chapter_pages(self.chapter)
    local cur = pages[self.page]
    local chars = self.doc:chars_into_chapter({ chapter = self.chapter, block = cur.last.block, offset = cur.last.offset })
        - self.doc:chars_into_chapter({ chapter = self.chapter, block = cur.first.block, offset = cur.first.offset })
    if self.page < #pages then
        self.page = self.page + 1
    elseif self.chapter < #self.doc.chapters then
        self:_goto({ chapter = self.chapter + 1, block = 1, offset = 0 })
    else
        self:_finished_book()
        return
    end
    self:_after_move(chars)
end

function Reader:prev_page()
    if self.page > 1 then
        self.page = self.page - 1
    elseif self.chapter > 1 then
        self:_goto({ chapter = self.chapter - 1, page = "last" })
    else
        return
    end
    self:_after_move(false)
end

function Reader:_finished_book()
    if self.stats:is_finished(self.book_id) then
        self.app:notify("End of book")
        return
    end
    self.stats:set_finished(self.book_id, true)
    self:_save()
    local y = self.stats:year()
    self.app:confirm({
        title = "You finished it!",
        text = string.format("%s is book %d you've finished in %s.", self.doc.title, y.finished, os.date("%Y")),
        ok_text = "Home", cancel_text = "Stay",
        on_ok = function() self.app:close_reader() end,
    })
end

function Reader:_set(key, value)
    local pos = self:position()
    self.state[key] = value
    self:_relayout()
    self:_goto(pos)
    self:_save()
    self.ui:set_dirty("full")
end

function Reader:set_font_size(size) self:_set("font_size", size) end
function Reader:set_line_spacing(v) self:_set("line_spacing", v) end

function Reader:goto_percent(pct)
    local target = pct / 100
    local total = 0
    for i = 1, #self.doc.chapters do total = total + self:_chapter_len(i) end
    local acc = 0
    for i = 1, #self.doc.chapters do
        local n = self:_chapter_len(i)
        if (acc + n) / total >= target or i == #self.doc.chapters then
            local frac = n > 0 and math.max(0, (target * total - acc) / n) or 0
            local pages = self:_chapter_pages(i)
            self.chapter = i
            self.page = math.max(1, math.min(#pages, math.floor(frac * #pages) + 1))
            break
        end
        acc = acc + n
    end
    self:_after_move(false)
end

------------------------------------------------------------------------------
-- Menus
------------------------------------------------------------------------------

function Reader:show_toc()
    local items = {}
    local cur_index
    local toc = self.doc.toc
    if #toc > 0 then
        for _, e in ipairs(toc) do
            if e.chapter then
                items[#items + 1] = { text = e.title, depth = e.depth, marked = e.chapter == self.chapter,
                    callback = function()
                        local c = self.doc:chapter(e.chapter)
                        local block = (e.fragment and c.ids[e.fragment]) or 1
                        self.ui:close(self.toc_view)
                        self:go_to({ chapter = e.chapter, block = block, offset = 0 })
                    end }
                if e.chapter == self.chapter and not cur_index then cur_index = #items end
            end
        end
    else
        for i = 1, #self.doc.chapters do
            items[#items + 1] = { text = self.doc:chapter_title(i), marked = i == self.chapter, callback = function()
                self.ui:close(self.toc_view)
                self:go_to({ chapter = i, block = 1, offset = 0 })
            end }
        end
        cur_index = self.chapter
    end
    self.toc_view = self.ui:show(W.ListView.new({ title = "Contents", items = items, start_index = cur_index }))
end

local function choice(text, is_checked, apply)
    return { text = text, checked = is_checked, callback = apply }
end

function Reader:display_items()
    local st = self.state
    local faces, sizes, spacings, margins, orient = {}, {}, {}, {}, {}
    for _, f in ipairs(FACES) do
        faces[#faces + 1] = choice(f[2], function() return st.face == f[1] end, function() self:_set("face", f[1]) end)
    end
    for _, s in ipairs(FONT_SIZES) do
        sizes[#sizes + 1] = choice(tostring(s), function() return st.font_size == s end, function() self:_set("font_size", s) end)
    end
    for _, v in ipairs({ 1.15, 1.3, 1.45, 1.6 }) do
        spacings[#spacings + 1] = choice(({ [1.15] = "Tight", [1.3] = "Normal", [1.45] = "Relaxed", [1.6] = "Loose" })[v],
            function() return st.line_spacing == v end, function() self:_set("line_spacing", v) end)
    end
    for _, k in ipairs(MARGIN_ORDER) do
        margins[#margins + 1] = choice(k:sub(1, 1):upper() .. k:sub(2), function() return st.margins == k end,
            function() self:_set("margins", k) end)
    end
    for _, r in ipairs({ 0, 90, 270, 180 }) do
        orient[#orient + 1] = choice(Rotation.NAMES[r], function() return (self.app.device.rotation or 0) == r end,
            function() self.app:set_rotation(r) end)
    end
    local face_name = "Caladea"
    for _, f in ipairs(FACES) do if f[1] == st.face then face_name = f[2] end end
    return {
        { text = function() return "Typeface: " .. face_name end, submenu = faces },
        { text = function() return "Font size: " .. st.font_size end, submenu = sizes },
        { text = "Line spacing", submenu = spacings },
        { text = function() return "Margins: " .. st.margins end, submenu = margins },
        { text = "Orientation", submenu = orient },
    }
end

function Reader:menu_items()
    local items = {
        { text = "Contents", callback = function() self:show_toc() end },
        { text = "Display", submenu = function() return self:display_items() end },
    }
    local gotos = {}
    for p = 0, 90, 10 do
        gotos[#gotos + 1] = { text = p .. "%", callback = function() self:goto_percent(p) end }
    end
    items[#items + 1] = { text = "Go to", submenu = gotos }
    if self.stats:is_finished(self.book_id) then
        items[#items + 1] = { text = "Mark as not finished", callback = function()
            self.stats:set_finished(self.book_id, false)
            self.app:notify("Marked as not finished")
        end }
    else
        items[#items + 1] = { text = "Mark as finished", callback = function()
            self.stats:set_finished(self.book_id, true)
            self.app:notify("Marked as finished")
        end }
    end
    -- Plugins add their entries (the recap plugin puts "Recap" second).
    self.app:collect_menu("Reader", items, self)
    items[#items + 1] = { text = "Home", callback = function() self.app:close_reader() end }
    return items
end

function Reader:show_menu()
    self.ui:show(W.Menu.new({ title = self.doc.title, items = self:menu_items() }))
end

------------------------------------------------------------------------------
-- Drawing
------------------------------------------------------------------------------

function Reader:_footer_text(pos)
    local mode = self.state.footer_mode
    local fmt = Stats.format_duration
    if mode == 1 then
        local left = fmt(pos.chapter_seconds_left) .. " left in chapter"
        if pos.page == pos.pages then left = "Last page of chapter" end
        return left, string.format("%.0f%%", pos.percent)
    elseif mode == 2 then
        return string.format("Page %d of %d", pos.page, pos.pages), fmt(pos.book_seconds_left, true) .. " left in book"
    elseif mode == 3 then
        local bat = self.app.device:battery()
        return os.date("%H:%M"), bat and string.format("Battery %d%%", bat) or ""
    end
    return nil, nil
end

function Reader:draw(c)
    local d = self.app.device
    c:fill_rect(0, 0, c.w, c.h, 255)
    self.layout:draw(c, self:_page())

    -- Status bar: a thin progress line with chapter ticks, text underneath.
    local pos = self:position()
    local mx = self.margin_x
    local bar_y = d.height - self.footer_h + math.floor(self.footer_h * 0.18)
    local bar_w = d.width - 2 * mx
    local frac = pos.percent / 100
    c:fill_rect(mx, bar_y, bar_w, 1, 170)
    c:fill_rect(mx, bar_y - 1, math.floor(bar_w * frac), 3, 0)
    local total, acc = 0, 0
    for i = 1, #self.doc.chapters do total = total + self:_chapter_len(i) end
    if #self.doc.chapters <= 60 and total > 0 then
        for i = 1, #self.doc.chapters - 1 do
            acc = acc + self:_chapter_len(i)
            c:fill_rect(mx + math.floor(bar_w * acc / total), bar_y - 4, 1, 9, 120)
        end
    end
    local left, right = self:_footer_text(pos)
    if left then
        local f = self.footer_font
        local y = bar_y + math.floor((d.height - bar_y) / 2) + math.floor(f.ascent / 3)
        c:text(f, right, d.width - mx - f:width(right), y, 70)
        c:text(f, W.fit(f, left, bar_w - f:width(right) - mx), mx, y, 70)
    end
end

function Reader:handle(ev)
    local d = self.app.device
    if ev.type == "key" then
        if ev.key == "next" or ev.key == "right" or ev.key == "down" then self:next_page()
        elseif ev.key == "prev" or ev.key == "left" or ev.key == "up" then self:prev_page()
        elseif ev.key == "menu" or ev.key == "select" then self:show_menu()
        elseif ev.key == "back" or ev.key == "home" then self.app:close_reader() end
    elseif ev.type == "swipe" then
        if ev.dir == "left" then self:next_page()
        elseif ev.dir == "right" then self:prev_page()
        elseif ev.dir == "down" and ev.y < d.height / 4 then self:show_menu() end
    elseif ev.type == "tap" then
        if ev.y < d.height / 8 then
            self:show_menu()
        elseif ev.y > d.height - self.footer_h then
            -- tap the status bar to cycle what it shows
            self.state.footer_mode = self.state.footer_mode % FOOTER_MODES + 1
            self:_save()
            self.ui:set_dirty("partial")
        elseif ev.x < d.width / 3 then
            self:prev_page()
        else
            self:next_page()
        end
    elseif ev.type == "hold" then
        self.app:broadcast("ReaderHold", self, ev)
    end
    return true
end

--- Device going to sleep: count the time on this page, stop the clock.
function Reader:pause()
    if self.last_turn_ms then
        self.stats:record(self.book_id, (self.app.device:monotonic_ms() - self.last_turn_ms) / 1000)
    end
    self.last_turn_ms = nil
    self:_save()
    self.stats:save()
end

function Reader:resume()
    self.last_turn_ms = self.app.device:monotonic_ms()
end

function Reader:close()
    if self.index_task then self.index_task.cancel() end
    -- count the last page's time
    if self.last_turn_ms then
        self.stats:record(self.book_id, (self.app.device:monotonic_ms() - self.last_turn_ms) / 1000)
    end
    self:_save()
    self.stats:save()
    self.doc:close()
end

return Reader
