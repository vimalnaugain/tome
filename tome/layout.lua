--[[
Paginates a parsed chapter into screen pages.

page = { lines = { {y=, items={ {x=, text=, font=} }, block=, offset=} },
         first = {block=, offset=}, last = {block=, offset=} }
`last` is exclusive: the first position NOT on the page.
--]]
local Font = require("tome.font")

local Layout = {}
Layout.__index = Layout

--- opts: width, height, margin_x, margin_top, margin_bottom, font_size,
--        line_spacing (multiplier), justify, face
function Layout.new(opts)
    local self = setmetatable({ opts = opts }, Layout)
    local face = opts.face or "serif"
    self.fonts = {
        r = Font.get(face, "r", opts.font_size),
        i = Font.get(face, "i", opts.font_size),
        b = Font.get(face, "b", opts.font_size),
        bi = Font.get(face, "bi", opts.font_size),
    }
    self.heading_fonts = {}
    for level = 1, 6 do
        local scale = ({ 1.5, 1.3, 1.15, 1.05, 1, 1 })[level]
        self.heading_fonts[level] = Font.get(face, "b", math.floor(opts.font_size * scale + 0.5))
    end
    local base = self.fonts.r
    self.line_h = math.floor(base.line_height * (opts.line_spacing or 1.25) + 0.5)
    self.para_gap = math.floor(self.line_h * (opts.paragraph_gap or 0.35))
    self.indent = math.floor(base.size * 1.3)
    self.text_w = opts.width - 2 * opts.margin_x
    self.top = opts.margin_top
    self.bottom = opts.height - opts.margin_bottom
    return self
end

local function is_space(c) return c == " " or c == "\194\160" end

--- Split a block into measured words: { text, font, offset, w, space_w, newline }
function Layout:_words(block, fonts)
    local words = {}
    local offset = 0
    for _, run in ipairs(block.runs) do
        local font = fonts[run.style] or fonts.r
        local t = run.text
        local i = 1
        local n = #t
        while i <= n do
            local c = t:sub(i, i)
            if c == "\n" then
                words[#words + 1] = { newline = true, offset = offset + i - 1 }
                i = i + 1
            elseif c == " " then
                if #words > 0 then words[#words].space_w = font:width(" ") end
                i = i + 1
            else
                local j = t:find("[ \n]", i) or n + 1
                local word = t:sub(i, j - 1)
                local prev = words[#words]
                if prev and not prev.newline and not prev.space_w and prev.font ~= font then
                    -- style change inside a word: keep it glued (no space)
                    words[#words + 1] = { text = word, font = font, offset = offset + i - 1, w = font:width(word), glue = true }
                else
                    words[#words + 1] = { text = word, font = font, offset = offset + i - 1, w = font:width(word) }
                end
                i = j
            end
        end
        offset = offset + n
    end
    return words
end

--- Break an over-long word into pieces that fit `maxw`.
local function split_long(word, maxw)
    local pieces = {}
    local cur, curw, start = {}, 0, word.offset
    local pos = word.offset
    for ch in word.text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        local cw = word.font:width(ch)
        if curw + cw > maxw and #cur > 0 then
            local t = table.concat(cur)
            pieces[#pieces + 1] = { text = t, font = word.font, offset = start, w = curw }
            cur, curw, start = {}, 0, pos
        end
        cur[#cur + 1] = ch
        curw = curw + cw
        pos = pos + #ch
    end
    if #cur > 0 then
        pieces[#pieces + 1] = { text = table.concat(cur), font = word.font, offset = start, w = curw, space_w = word.space_w }
    end
    return pieces
end

--- Lay out one block into lines (not yet assigned to pages).
function Layout:_block_lines(block, bi, first_in_chapter, after_heading)
    local o = self.opts
    local lines = {}
    if block.kind == "hr" then
        return { { hr = true, height = self.line_h, block = bi, offset = 0 } }
    end
    local fonts, align, indent, left = self.fonts, o.justify and "justify" or "left", 0, 0
    local line_h = self.line_h
    if block.kind == "h" then
        local f = self.heading_fonts[block.level or 2]
        fonts = { r = f, i = f, b = f, bi = f }
        align = "center"
        line_h = math.floor(f.line_height * 1.2 + 0.5)
    elseif block.kind == "quote" or block.kind == "li" then
        left = math.floor(self.indent * 0.8)
    elseif block.kind == "pre" then
        align = "left"
    elseif not after_heading and not first_in_chapter and o.indent ~= false then
        indent = self.indent
    end
    local maxw = self.text_w - left

    local words = self:_words(block, fonts)
    local expanded = {}
    for _, w in ipairs(words) do
        if not w.newline and w.w > maxw then
            for _, p in ipairs(split_long(w, maxw)) do expanded[#expanded + 1] = p end
        else
            expanded[#expanded + 1] = w
        end
    end
    words = expanded

    local i = 1
    local first_line = true
    while i <= #words do
        local avail = maxw - (first_line and indent or 0)
        local start = i
        local w = 0
        local forced = false
        while i <= #words do
            local wd = words[i]
            if wd.newline then forced = true; i = i + 1; break end
            local space = (i > start and not wd.glue) and (words[i - 1].space_w or 0) or 0
            if i > start and w + space + wd.w > avail then break end
            w = w + space + wd.w
            i = i + 1
        end
        local stop = i - 1
        if forced then stop = stop - 1 end
        local items = {}
        local last_line = i > #words or forced
        -- natural widths
        local nat, gaps = 0, 0
        for k = start, stop do
            nat = nat + words[k].w
            if k > start and not words[k].glue then
                nat = nat + (words[k - 1].space_w or 0)
                gaps = gaps + 1
            end
        end
        local x = o.margin_x + left + (first_line and indent or 0)
        local extra = 0
        if align == "center" then
            x = o.margin_x + left + (maxw - nat) / 2
        elseif align == "justify" and not last_line and gaps > 0 then
            extra = (avail - nat) / gaps
        end
        for k = start, stop do
            local wd = words[k]
            if k > start and not wd.glue then x = x + (words[k - 1].space_w or 0) + extra end
            items[#items + 1] = { x = x, text = wd.text, font = wd.font }
            x = x + wd.w
        end
        local offset = words[start] and (words[start].offset or 0) or 0
        lines[#lines + 1] = { items = items, height = line_h, block = bi, offset = offset,
            ascent = fonts.r.ascent }
        first_line = false
    end
    return lines
end

--- Paginate a chapter. Returns array of pages.
function Layout:paginate(chapter)
    local pages = {}
    local page = { lines = {} }
    local y = self.top
    local function new_page()
        if #page.lines > 0 then pages[#pages + 1] = page end
        page = { lines = {} }
        y = self.top
    end
    local prev_kind = nil
    for bi, block in ipairs(chapter.blocks) do
        local lines = self:_block_lines(block, bi, bi == 1, prev_kind == "h")
        local gap = 0
        if #page.lines > 0 then
            if block.kind == "h" then gap = self.line_h
            elseif prev_kind == "h" then gap = math.floor(self.line_h * 0.5)
            else gap = self.para_gap end
        end
        if block.kind == "h" and #page.lines > 0 and y + gap + 3 * self.line_h > self.bottom then
            new_page() -- don't strand a heading at the bottom of a page
            gap = 0
        end
        y = y + gap
        for _, line in ipairs(lines) do
            if y + line.height > self.bottom and #page.lines > 0 then new_page() end
            line.y = y + (line.ascent or 0) + math.floor((line.height - (line.ascent or 0)) * 0.25)
            line.top = y
            page.lines[#page.lines + 1] = line
            y = y + line.height
        end
        prev_kind = block.kind
    end
    new_page()
    if #pages == 0 then pages[1] = { lines = {} } end
    for pi, p in ipairs(pages) do
        local first = p.lines[1]
        p.first = first and { block = first.block, offset = first.offset } or { block = 1, offset = 0 }
        local nextp = pages[pi + 1]
        p.last = nextp and nextp.lines[1] and { block = nextp.lines[1].block, offset = nextp.lines[1].offset }
            or { block = #chapter.blocks + 1, offset = 0 }
    end
    return pages
end

--- Index of the page containing (block, offset).
function Layout.find_page(pages, block, offset)
    local found = 1
    for i, p in ipairs(pages) do
        local f = p.first
        if f.block < block or (f.block == block and f.offset <= offset) then found = i else break end
    end
    return found
end

--- Draw a page onto a canvas.
function Layout:draw(canvas, page)
    for _, line in ipairs(page.lines) do
        if line.hr then
            local w = math.floor(self.text_w * 0.3)
            canvas:fill_rect(self.opts.margin_x + (self.text_w - w) / 2, line.top + line.height / 2, w, 2, 80)
        else
            for _, it in ipairs(line.items) do
                canvas:text(it.font, it.text, it.x, line.y, 0, self.opts.weight)
            end
        end
    end
end

return Layout
