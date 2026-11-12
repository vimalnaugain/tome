--[[
Recap engine: builds spoiler-safe "story so far" recaps from the text the
reader has already passed.

Strategy
  * Short books / early in a book: send everything read so far in one call.
  * Otherwise: summarize each finished chapter once (cached on disk per book),
    then combine those summaries with the last pages verbatim.
  * Quick recap: last pages verbatim + any cached chapter summaries, one call.

Nothing after the end of the current page is ever sent to the model.
--]]
local plugin = ...
local util = require("tome.util")

local Recap = {}
Recap.__index = Recap

local CACHE_VERSION = 1

local SYSTEM = [[You help a reader pick a book back up after a break.
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

function Recap.new(opts)
    local self = setmetatable({}, Recap)
    self.reader = opts.reader
    self.provider = opts.provider
    self.progress = opts.progress or function() end
    self.settings = plugin.settings
    self.book = self.reader:book_info()
    self.cache_path = self.settings:data_dir() .. "/" .. self.book.id .. ".lua"
    self.cache = util.load_table(self.cache_path) or {}
    if self.cache.version ~= CACHE_VERSION then self.cache = { version = CACHE_VERSION, chapters = {} } end
    return self
end

function Recap:_title(i)
    self.titles = self.titles or self.reader:chapters()
    return self.titles[i] and self.titles[i].title or ("Section " .. i)
end

function Recap:_save_cache()
    util.save_table(self.cache_path, self.cache)
end

local function book_header(book)
    local by = (book.authors and #book.authors > 0) and (" by " .. table.concat(book.authors, ", ")) or ""
    return string.format("Book: %s%s", book.title or "?", by)
end

--- Chapter summaries cached for chapters < upto. Returns list, missing indexes.
function Recap:_cached_summaries(upto)
    local have, missing = {}, {}
    for i = 1, upto - 1 do
        local c = self.cache.chapters[i]
        local text_len = #self.reader:chapter_text(i)
        if text_len < 200 then
            -- front matter, dedications, etc.: not worth a call
        elseif c and c.chars == text_len then
            have[#have + 1] = { index = i, title = self:_title(i), summary = c.summary }
        else
            missing[#missing + 1] = i
        end
    end
    return have, missing
end

function Recap:_summarize_chapter(i, total_missing, done)
    local title = self:_title(i)
    local text = self.reader:chapter_text(i)
    local chunk_chars = self.settings:get("chunk_chars", 120000)
    self.progress(string.format("Summarizing chapter %d of %d\n%s", done, total_missing, title))
    local pieces = {}
    if #text > chunk_chars then
        -- Very long chapter: summarize in parts, then merge.
        local pos = 1
        while pos <= #text do
            local stop = math.min(#text, pos + chunk_chars - 1)
            local nl = text:find("\n\n", stop, true)
            if nl and nl - stop < 4000 then stop = nl end
            pieces[#pieces + 1] = text:sub(pos, stop)
            pos = stop + 1
        end
    else
        pieces[1] = text
    end
    local notes = {}
    for pi, piece in ipairs(pieces) do
        local user = string.format([[%s
Chapter: %s%s

<chapter_text>
%s
</chapter_text>

Write notes on this chapter so a reader can be reminded of it later: the key events in order, who is involved (and how characters relate), important places or objects, and open questions the chapter raises. 120-250 words, bullets are fine. Do not add a heading.]],
            book_header(self.book), title, #pieces > 1 and string.format(" (part %d of %d)", pi, #pieces) or "", piece)
        local out, err = self.provider.complete(SYSTEM, user, { effort = "low", max_tokens = 4000 })
        if not out then return nil, err end
        notes[#notes + 1] = util.trim(out)
    end
    local summary = table.concat(notes, "\n")
    self.cache.chapters[i] = { summary = summary, chars = #text, model = self.provider.model, at = os.time() }
    self:_save_cache()
    return summary
end

--- How many chapter summaries a full recap would need to create first.
function Recap:pending_chapter_summaries()
    local pos = self.reader:page_end()
    local read_text = self.reader:text_range(nil, pos)
    if #read_text <= self.settings:get("single_pass_chars", 200000) then return 0, 0, #read_text end
    local _, missing = self:_cached_summaries(pos.chapter)
    local chars = 0
    for _, i in ipairs(missing) do chars = chars + #self.reader:chapter_text(i) end
    return #missing, chars, #read_text
end

local function format_request(self, kind)
    local length = LENGTHS[self.settings:get("length", "medium")] or LENGTHS.medium
    local pos = self.reader:position()
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

--- Full "story so far" recap.
function Recap:story_so_far()
    local pos = self.reader:page_end()
    local single = self.settings:get("single_pass_chars", 200000)
    local recent_chars = self.settings:get("recent_chars", 12000)
    local read_text = self.reader:text_range(nil, pos)
    local where, instructions = format_request(self, "full")
    local user
    if #read_text <= single then
        self.progress("Writing your recap\226\128\166")
        user = string.format("%s\n%s\n\n<book_text_so_far>\n%s\n</book_text_so_far>\n\n%s",
            book_header(self.book), where, read_text, instructions)
    else
        local have, missing = self:_cached_summaries(pos.chapter)
        for n, i in ipairs(missing) do
            local _, err = self:_summarize_chapter(i, #missing, n)
            if err then return nil, err end
        end
        have = self:_cached_summaries(pos.chapter)
        local notes = {}
        for _, s in ipairs(have) do notes[#notes + 1] = string.format("### %s\n%s", s.title, s.summary) end
        local recent = self.reader:text_read_so_far(recent_chars)
        self.progress("Writing your recap\226\128\166")
        user = string.format([[%s
%s

<chapter_notes>
%s
</chapter_notes>

<most_recent_pages>
%s
</most_recent_pages>

The chapter notes cover the earlier chapters; the most recent pages are verbatim and end at the reader's position.

%s]], book_header(self.book), where, table.concat(notes, "\n\n"), recent, instructions)
    end
    return self.provider.complete(SYSTEM, user, { effort = self.settings:get("effort", "medium"), max_tokens = 8000 })
end

--- Quick recap: recent pages + whatever chapter notes are already cached.
function Recap:quick()
    local pos = self.reader:page_end()
    local recent = self.reader:text_read_so_far(self.settings:get("quick_recent_chars", 15000))
    local have = self:_cached_summaries(pos.chapter)
    local notes = {}
    for _, s in ipairs(have) do notes[#notes + 1] = string.format("### %s\n%s", s.title, s.summary) end
    local where, instructions = format_request(self, "quick")
    self.progress("Writing a quick recap\226\128\166")
    local user = string.format("%s\n%s\n\n%s<most_recent_pages>\n%s\n</most_recent_pages>\n\n%s",
        book_header(self.book), where,
        #notes > 0 and ("<chapter_notes>\n" .. table.concat(notes, "\n\n") .. "\n</chapter_notes>\n\n") or "",
        recent, instructions)
    return self.provider.complete(SYSTEM, user, { effort = "low", max_tokens = 4000 })
end

function Recap:clear_cache()
    os.remove(self.cache_path)
    self.cache = { version = CACHE_VERSION, chapters = {} }
end

return Recap
