--[[--
Recap engine: builds spoiler-free "story so far" recaps from the text the
reader has already passed. Ported from Tome's recap plugin.

Strategy
  * Short books / early in a book: send everything read so far in one call.
  * Otherwise: summarize each finished section once (cached per book),
    then combine those notes with the last pages verbatim.
  * Quick recap: last pages verbatim + any cached section notes, one call.

Nothing after the end of the current page is ever sent to the model: the
book adapter (book.lua) only returns text up to there.

This file has no KOReader dependencies so it can be tested on its own.

Engine.new{
    book = adapter,              -- see book.lua
    complete = function(system, user, opts) -> text | nil, err
    progress = function(msg) -> false to cancel (optional)
    get = function(key, default) -> setting value
    cache = table,               -- per-book cache table (mutated)
    save_cache = function(),     -- persist `cache`
    model = "model id",          -- recorded with each section note
}
--]]
local Engine = {}
Engine.__index = Engine

Engine.CACHE_VERSION = 1

Engine.SYSTEM = [[You help a reader pick a book back up after a break.
Rules:
- Use ONLY the book text and chapter notes you are given. Even if you recognise the book, never use outside knowledge of it, its sequels or adaptations.
- Never hint at, predict or speculate about anything after the point the reader reached. The reader's position is the end of the provided text.
- Write in plain, warm prose in the book's language. Use character names as the book does.
- Keep formatting simple: "## " headings, short paragraphs, "- " bullets, **bold** for names on first mention. No tables.]]

local LENGTHS = {
    short = "about 120 words in total",
    medium = "about 300 words in total",
    long = "about 600 words in total",
}
Engine.LENGTHS = LENGTHS

local MIN_SECTION_CHARS = 200 -- front matter, part titles, dedications: not worth a call

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Move a byte index forward to the start of a UTF-8 character.
local function char_start(s, i)
    while i <= #s do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i + 1
    end
    return i
end

--- The last `n` bytes of `s`, starting at a paragraph (or at least a character) boundary.
function Engine.tail(s, n)
    if #s <= n then return s end
    local start = #s - n + 1
    local nl = s:find("\n", start, true)
    if nl and nl - start < 2000 and nl < #s then
        start = nl + 1
    else
        start = char_start(s, start)
    end
    return s:sub(start)
end

--- Split `text` into pieces of about `size` bytes, preferring paragraph breaks.
function Engine.split(text, size)
    if #text <= size then return { text } end
    local pieces, pos = {}, 1
    while pos <= #text do
        local stop = math.min(#text, pos + size - 1)
        if stop < #text then
            local _, nl = text:find("\n\n", stop, true)
            if not nl then _, nl = text:find("\n", stop, true) end
            if nl and nl - stop < 4000 then
                stop = nl
            else
                stop = char_start(text, stop + 1) - 1
            end
        end
        pieces[#pieces + 1] = text:sub(pos, stop)
        pos = stop + 1
    end
    return pieces
end

function Engine.new(opts)
    local self = setmetatable({}, Engine)
    self.book = opts.book
    self.complete = opts.complete
    self.progress = opts.progress or function() return true end
    self.get = opts.get or function(_, default) return default end
    self.save_cache = opts.save_cache or function() end
    self.model = opts.model
    self.cache = opts.cache or {}
    if self.cache.version ~= Engine.CACHE_VERSION or type(self.cache.sections) ~= "table" then
        for k in pairs(self.cache) do self.cache[k] = nil end
        self.cache.version = Engine.CACHE_VERSION
        self.cache.sections = {}
    end
    return self
end

function Engine:_say(msg)
    if self.progress(msg) == false then return false end
    return true
end

function Engine:_read_text()
    if not self.read_text then self.read_text = self.book:read_text() or "" end
    return self.read_text
end

function Engine:_sections()
    if not self.sections then self.sections = self.book:finished_sections() or {} end
    return self.sections
end

local function book_header(info)
    local by = (info.authors and #info.authors > 0) and (" by " .. table.concat(info.authors, ", ")) or ""
    return string.format("Book: %s%s", info.title or "?", by)
end

--- Notes cached for finished sections. Returns list of {title, summary}, list of missing sections.
function Engine:_cached_notes()
    local have, missing = {}, {}
    for _, sec in ipairs(self:_sections()) do
        local len = sec.length or #sec.text()
        if len >= MIN_SECTION_CHARS then
            local c = self.cache.sections[sec.key]
            if c and c.chars == len then
                have[#have + 1] = { title = sec.title, summary = c.summary }
            else
                missing[#missing + 1] = sec
            end
        end
    end
    return have, missing
end

function Engine:_summarize_section(sec, total_missing, n)
    local text = sec.text()
    local pieces = Engine.split(text, self.get("chunk_chars", 120000))
    local notes = {}
    for pi, piece in ipairs(pieces) do
        local msg = string.format("Summarizing chapter %d of %d\n%s", n, total_missing, sec.title)
        if #pieces > 1 then msg = msg .. string.format(" (part %d of %d)", pi, #pieces) end
        if not self:_say(msg) then return nil, "cancelled" end
        local user = string.format([[%s
Chapter: %s%s

<chapter_text>
%s
</chapter_text>

Write notes on this chapter so a reader can be reminded of it later: the key events in order, who is involved (and how characters relate), important places or objects, and open questions the chapter raises. 120-250 words, bullets are fine. Do not add a heading.]],
            book_header(self.book:info()), sec.title,
            #pieces > 1 and string.format(" (part %d of %d)", pi, #pieces) or "", piece)
        local out, err = self.complete(Engine.SYSTEM, user, { effort = "low", max_tokens = 4000 })
        if not out then return nil, err end
        notes[#notes + 1] = trim(out)
    end
    local summary = table.concat(notes, "\n")
    self.cache.sections[sec.key] = { summary = summary, chars = #text, model = self.model, at = os.time() }
    self.save_cache()
    return summary
end

--- How many section notes a full recap would need to write first: count, chars.
function Engine:pending()
    local read = self:_read_text()
    if #read <= self.get("single_pass_chars", 200000) then return 0, 0 end
    local _, missing = self:_cached_notes()
    local chars = 0
    for _, sec in ipairs(missing) do chars = chars + (sec.length or #sec.text()) end
    return #missing, chars
end

function Engine:_request(kind)
    local length = LENGTHS[self.get("length", "medium")] or LENGTHS.medium
    local pos = self.book:position()
    local where = string.format("The reader stopped %.0f%% of the way through the book, in \"%s\".",
        pos.percent or 0, pos.chapter_title or "?")
    if kind == "quick" then
        return where, string.format([[Give a quick refresher (%s, at most half of it on earlier chapters) with these sections:
## Previously
(only if chapter notes are given: the story before the recent pages, very briefly)
## Where you left off
(what is happening in the most recent pages, ending exactly where the text ends)
## Who's who
(only the characters active in the recent pages, one short bullet each)]], length)
    end
    return where, string.format([[Write a recap of the story so far (%s) with these sections:
## The story so far
## Where you left off
(the situation at the exact end of the text)
## Characters to remember
(one short bullet each, most important first)
## Open threads
(unresolved questions the reader should keep in mind, without guessing answers)]], length)
end

local function notes_block(have)
    local notes = {}
    for _, s in ipairs(have) do notes[#notes + 1] = string.format("### %s\n%s", s.title, s.summary) end
    return table.concat(notes, "\n\n")
end

--- Full "story so far" recap. Returns text | nil, err ("cancelled" if the user stopped it).
function Engine:story_so_far()
    local read = self:_read_text()
    if #read == 0 then return nil, "No text has been read yet." end
    local header = book_header(self.book:info())
    local where, instructions = self:_request("full")
    local user
    if #read <= self.get("single_pass_chars", 200000) then
        if not self:_say("Writing your recap\u{2026}") then return nil, "cancelled" end
        user = string.format("%s\n%s\n\n<book_text_so_far>\n%s\n</book_text_so_far>\n\n%s",
            header, where, read, instructions)
    else
        local _, missing = self:_cached_notes()
        for n, sec in ipairs(missing) do
            local _, err = self:_summarize_section(sec, #missing, n)
            if err then return nil, err end
        end
        local have = self:_cached_notes()
        local recent = Engine.tail(read, self.get("recent_chars", 12000))
        if not self:_say("Writing your recap\u{2026}") then return nil, "cancelled" end
        user = string.format([[%s
%s

<chapter_notes>
%s
</chapter_notes>

<most_recent_pages>
%s
</most_recent_pages>

The chapter notes cover the earlier chapters; the most recent pages are verbatim and end at the reader's position.

%s]], header, where, notes_block(have), recent, instructions)
    end
    return self.complete(Engine.SYSTEM, user, { effort = self.get("effort", "medium"), max_tokens = 8000 })
end

--- Quick recap: recent pages + whatever section notes are already cached.
function Engine:quick()
    local read = self:_read_text()
    if #read == 0 then return nil, "No text has been read yet." end
    local recent = Engine.tail(read, self.get("quick_recent_chars", 15000))
    local have = {}
    if #read > #recent then have = self:_cached_notes() end
    local where, instructions = self:_request("quick")
    if not self:_say("Writing a quick recap\u{2026}") then return nil, "cancelled" end
    local user = string.format("%s\n%s\n\n%s<most_recent_pages>\n%s\n</most_recent_pages>\n\n%s",
        book_header(self.book:info()), where,
        #have > 0 and ("<chapter_notes>\n" .. notes_block(have) .. "\n</chapter_notes>\n\n") or "",
        recent, instructions)
    return self.complete(Engine.SYSTEM, user, { effort = "low", max_tokens = 4000 })
end

--- Light Markdown → plain text for KOReader's text viewer.
function Engine.to_plain(md)
    local out = {}
    for line in (md .. "\n"):gmatch("(.-)\r?\n") do
        local h = line:match("^#+%s+(.*)$")
        if h then
            if #out > 0 and out[#out] ~= "" then out[#out + 1] = "" end
            line = "\u{25A0} " .. h
        else
            local indent, rest = line:match("^(%s*)[-*]%s+(.*)$")
            if rest then line = indent .. "\u{2022} " .. rest end
        end
        line = line:gsub("%*%*(.-)%*%*", "%1"):gsub("__(.-)__", "%1")
        out[#out + 1] = line
    end
    while out[#out] == "" do out[#out] = nil end
    return table.concat(out, "\n")
end

return Engine
