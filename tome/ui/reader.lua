--[[
Reader view: shows one EPUB page at a time, handles page turns, the reader
menu and per-book state (position, font size). It is also the object
plugins receive as `reader` -- see docs/PLUGIN_API.md for the public part.
--]]
local Epub = require("tome.epub")
local Layout = require("tome.layout")
local W = require("tome.ui.widgets")
local util = require("tome.util")
local log = require("tome.log")

local Reader = {}
Reader.__index = Reader

local FONT_SIZES = { 22, 26, 30, 34, 40, 46, 54 }

function Reader.open(app, path)
    local doc, err = Epub.open(path)
    if not doc then return nil, err end
    local self = setmetatable({ app = app, doc = doc, path = path, pages = {}, refresh_mode = "full",
        fullscreen = true }, Reader)
    self.book_id = util.file_fingerprint(path)
    self.state_path = app.data_dir .. "/books/" .. self.book_id .. ".lua"
    local defaults = app.settings.reader or {}
    self.state = util.load_table(self.state_path) or {}
    self.state.font_size = self.state.font_size or defaults.font_size or (app.device.dpi >= 250 and 34 or 22)
    self.state.line_spacing = self.state.line_spacing or defaults.line_spacing or 1.3
    self.state.position = self.state.position or { chapter = 1, block = 1, offset = 0 }
    self.previous_read = self.state.last_read -- before this session
    self.state.title = doc.title
    self.state.path = path
    self.page_turns = 0
    self:_relayout()
    self:_goto(self.state.position)
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
-- { chapter, block, offset, percent, chapter_title, page, pages }
function Reader:position()
    local p = self:_page()
    local pos = { chapter = self.chapter, block = p.first.block, offset = p.first.offset }
    pos.percent = math.floor(self.doc:progress(pos) * 1000 + 0.5) / 10
    pos.chapter_title = self.doc:chapter_title(self.chapter)
    pos.page, pos.pages = self.page, #self.pages[self.chapter]
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
    -- Walk back chapter by chapter until we have enough text.
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

--- Jump to a position table {chapter, block, offset}.
function Reader:go_to(pos)
    self:_goto(pos)
    self:_after_move()
end

------------------------------------------------------------------------------
-- Internals
------------------------------------------------------------------------------

function Reader:_relayout()
    local d = self.app.device
    local dpi = d.dpi
    local footer_h = math.floor(dpi * 0.28)
    self.footer_h = footer_h
    self.layout = Layout.new({
        width = d.width, height = d.height,
        margin_x = math.floor(dpi * 0.2), margin_top = math.floor(dpi * 0.2),
        margin_bottom = footer_h + math.floor(dpi * 0.06),
        font_size = self.state.font_size, line_spacing = self.state.line_spacing,
        justify = (self.app.settings.reader or {}).justify ~= false,
    })
    self.footer_font = require("tome.font").get("sans", "r", math.floor(dpi * 0.075))
    self.pages = {}
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
    self.state.position = { chapter = self.chapter, block = p.first.block, offset = p.first.offset }
    self.state.percent = self.doc:progress(self.state.position)
    self.state.last_read = os.time()
    util.save_table(self.state_path, self.state)
end

function Reader:_after_move()
    self:_save()
    self.page_turns = self.page_turns + 1
    self.ui:set_dirty("partial")
    self.app:broadcast("PageChanged", self, self:position())
end

function Reader:next_page()
    local pages = self:_chapter_pages(self.chapter)
    if self.page < #pages then
        self.page = self.page + 1
    elseif self.chapter < #self.doc.chapters then
        self:_goto({ chapter = self.chapter + 1, block = 1, offset = 0 })
    else
        self.app:notify("End of book")
        return
    end
    self:_after_move()
end

function Reader:prev_page()
    if self.page > 1 then
        self.page = self.page - 1
    elseif self.chapter > 1 then
        self:_goto({ chapter = self.chapter - 1, page = "last" })
    else
        return
    end
    self:_after_move()
end

function Reader:set_font_size(size)
    local pos = self:position()
    self.state.font_size = size
    self:_relayout()
    self:_goto(pos)
    self:_save()
    self.ui:set_dirty("full")
end

function Reader:set_line_spacing(v)
    local pos = self:position()
    self.state.line_spacing = v
    self:_relayout()
    self:_goto(pos)
    self:_save()
    self.ui:set_dirty("full")
end

function Reader:goto_percent(pct)
    local target = pct / 100 * self.doc.total_size
    for i, ch in ipairs(self.doc.chapters) do
        if target < ch.start + ch.size or i == #self.doc.chapters then
            local frac = math.max(0, (target - ch.start) / ch.size)
            local pages = self:_chapter_pages(i)
            self.chapter = i
            self.page = math.max(1, math.min(#pages, math.floor(frac * #pages) + 1))
            break
        end
    end
    self:_after_move()
end

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

function Reader:menu_items()
    local items = {
        { text = "Table of contents", callback = function() self:show_toc() end },
    }
    local sizes = {}
    for _, s in ipairs(FONT_SIZES) do
        sizes[#sizes + 1] = { text = tostring(s) .. " px", checked = function() return self.state.font_size == s end,
            callback = function() self:set_font_size(s) end }
    end
    items[#items + 1] = { text = "Font size", submenu = sizes }
    local spacings = {}
    for _, v in ipairs({ 1.1, 1.2, 1.3, 1.45, 1.6 }) do
        spacings[#spacings + 1] = { text = string.format("%.2f", v), checked = function() return self.state.line_spacing == v end,
            callback = function() self:set_line_spacing(v) end }
    end
    items[#items + 1] = { text = "Line spacing", submenu = spacings }
    local gotos = {}
    for p = 0, 90, 10 do
        gotos[#gotos + 1] = { text = p .. "%", callback = function() self:goto_percent(p) end }
    end
    items[#items + 1] = { text = "Go to", submenu = gotos }
    -- Plugins append their entries here.
    self.app:collect_menu("Reader", items, self)
    items[#items + 1] = { text = "Close book", callback = function() self.app:close_reader() end }
    items[#items + 1] = { text = "Exit Tome", callback = function() self.app:quit() end }
    return items
end

function Reader:show_menu()
    self.ui:show(W.Menu.new({ title = self.doc.title, items = self:menu_items() }))
end

function Reader:draw(c)
    local page = self:_page()
    self.layout:draw(c, page)
    -- footer: chapter title · page/pages · percent
    local f = self.footer_font
    local d = self.app.device
    local y = d.height - math.floor(self.footer_h / 2) + math.floor(f.ascent / 2)
    local mx = math.floor(d.dpi * 0.2)
    local pos = self:position()
    local right = string.format("%d/%d  \194\183  %.0f%%", pos.page, pos.pages, pos.percent)
    local bat = d:battery()
    if bat then right = right .. string.format("  \194\183  %d%%", bat) end
    c:text(f, right, d.width - mx - f:width(right), y, 60)
    c:text(f, W.fit(f, pos.chapter_title or "", d.width - 3 * mx - f:width(right)), mx, y, 60)
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
        elseif ev.x < d.width / 3 then
            self:prev_page()
        else
            self:next_page()
        end
    elseif ev.type == "hold" then
        self.app:broadcast("ReaderHold", self, ev)
    end
    -- Periodic full refresh is handled by the device (flash_every).
    return true
end

function Reader:close()
    self:_save()
    self.doc:close()
end

return Reader
