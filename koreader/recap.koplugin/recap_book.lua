--[[--
Book adapter: the text the reader has already passed, for the recap engine.

Reflowable books (EPUB, FB2, MOBI, HTML, TXT… via crengine) use XPointers;
fixed-layout books (PDF, DjVu, CBZ with text) use page numbers.

The spoiler boundary is the end of the last word on screen (crengine) or the
end of the current page (PDF/DjVu). Nothing after it is ever returned.

Sections come from the table of contents. Without one, the text is cut into
fixed-size parts so long books can still be summarized incrementally.
--]]
local Screen = require("device").screen
local logger = require("logger")

local Book = {}
Book.__index = Book

local NO_TOC_PART_CHARS = 60000

function Book.new(ui)
    local self = setmetatable({}, Book)
    self.ui = ui
    self.doc = ui.document
    self.rolling = ui.rolling ~= nil and ui.paging == nil
    self.cur = ui:getCurrentPage()
    self.count = self.doc:getPageCount()
    return self
end

function Book:info()
    local props = self.ui.doc_props or self.ui.doc_settings:readSetting("doc_props") or {}
    local title = props.display_title or props.title
    if not title or title == "" then
        title = (self.doc.file or "?"):match("([^/]+)$"):gsub("%.[^.]+$", "")
    end
    local authors = {}
    if type(props.authors) == "string" then
        for a in props.authors:gmatch("[^\n]+") do authors[#authors + 1] = a end
    end
    return { title = title, authors = authors }
end

function Book:position()
    local percent = self.count > 0 and (self.cur / self.count * 100) or 0
    local title
    if self.ui.toc then title = self.ui.toc:getTocTitleByPage(self.cur) end
    if not title or title == "" then title = "page " .. self.cur end
    return { percent = percent, chapter_title = title }
end

--- Stable id for the current book (for logs only).
function Book:id()
    return self.doc.file
end

-- Reflowable documents --------------------------------------------------

function Book:_end_xp()
    if self.end_xp then return self.end_xp end
    local doc = self.doc
    -- End of the last word on screen: exact, and right in two-page mode too.
    local ok, range = pcall(doc.getTextFromPositions, doc, { x = 0, y = 0 },
        { x = Screen:getWidth(), y = Screen:getHeight() }, true)
    if ok and range and range.pos1 then
        self.end_xp = range.pos1
    else
        local visible = doc.getVisiblePageCount and doc:getVisiblePageCount() or 1
        local nxt = self.cur + visible
        self.end_xp = doc:getPageXPointer(math.min(nxt, self.count))
    end
    if doc.clearSelection then doc:clearSelection() end
    return self.end_xp
end

function Book:_xp_text(xp0, xp1)
    local doc = self.doc
    if not xp0 or not xp1 or xp0 == xp1 then return "" end
    local ok, text = pcall(doc.getTextFromXPointers, doc, xp0, xp1)
    if doc.clearSelection then doc:clearSelection() end
    if not ok then
        logger.warn("recap: getTextFromXPointers failed", text)
        return ""
    end
    return text or ""
end

-- Fixed-layout documents ------------------------------------------------

function Book:_page_text(page)
    local ok, lines = pcall(self.doc.getPageText, self.doc, page)
    if not ok or type(lines) ~= "table" then return "" end
    local out = {}
    for _, line in ipairs(lines) do
        local words = {}
        for _, w in ipairs(line) do
            if type(w) == "table" and w.word then words[#words + 1] = w.word end
        end
        if #words > 0 then out[#out + 1] = table.concat(words, " ") end
    end
    return table.concat(out, "\n")
end

function Book:_pages_text(first, last)
    local out = {}
    for p = first, last do
        local t = self:_page_text(p)
        if t ~= "" then out[#out + 1] = t end
    end
    return table.concat(out, "\n\n")
end

-- Engine interface --------------------------------------------------------

--- All text from the start of the book to the end of the current screen.
function Book:read_text()
    if self.read then return self.read end
    if self.rolling then
        self.read = self:_xp_text(self.doc:getPageXPointer(1), self:_end_xp())
    else
        self.read = self:_pages_text(1, self.cur)
    end
    return self.read
end

--- ToC entries in reading order, one per distinct start point.
function Book:_toc()
    local toc = self.ui.toc
    if not toc then return {} end
    pcall(toc.fillToc, toc)
    local entries = {}
    for _, e in ipairs(toc.toc or {}) do
        if e.page and (not self.rolling or e.xpointer) then entries[#entries + 1] = e end
    end
    table.sort(entries, function(a, b) return a.page < b.page end)
    local out, seen = {}, {}
    for _, e in ipairs(entries) do
        local key = self.rolling and e.xpointer or ("p" .. e.page)
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = { key = key, page = e.page, xpointer = e.xpointer,
                title = (e.title or ""):gsub("^%s+", ""):gsub("%s+$", "") }
        end
    end
    return out
end

--- Sections that end before the reader's current section begins.
-- Each: { key, title, text = function() -> string }
function Book:finished_sections()
    local toc = self:_toc()
    local sections = {}
    if #toc == 0 then
        -- No ToC: fixed-size parts of the text read so far (all but the current one).
        local read = self:read_text()
        local n = math.floor(#read / NO_TOC_PART_CHARS)
        for i = 1, n - 1 do
            local a, b = (i - 1) * NO_TOC_PART_CHARS + 1, i * NO_TOC_PART_CHARS
            sections[#sections + 1] = {
                key = "part:" .. NO_TOC_PART_CHARS .. ":" .. i,
                title = "Part " .. i,
                length = b - a + 1,
                text = function() return read:sub(a, b) end,
            }
        end
        return sections
    end
    -- Text before the first ToC entry (prologue without an entry, front matter).
    local bounds = {}
    if toc[1].page > 1 then
        bounds[1] = { key = self.rolling and "start" or "p1", page = 1,
            xpointer = self.rolling and self.doc:getPageXPointer(1) or nil, title = "Opening pages" }
    end
    for _, e in ipairs(toc) do bounds[#bounds + 1] = e end
    for i = 1, #bounds - 1 do
        local s, nxt = bounds[i], bounds[i + 1]
        if nxt.page > self.cur then break end -- s is the section being read
        local title = s.title ~= "" and s.title or ("Section " .. i)
        local text
        if self.rolling then
            text = function() return self:_xp_text(s.xpointer, nxt.xpointer) end
        else
            local last = math.max(s.page, nxt.page - 1)
            text = function() return self:_pages_text(s.page, last) end
        end
        local cached
        sections[#sections + 1] = {
            key = s.key, title = title,
            text = function()
                if not cached then cached = text() end
                return cached
            end,
        }
    end
    return sections
end

return Book
