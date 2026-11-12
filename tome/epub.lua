--[[
EPUB 2/3 document: metadata, spine, table of contents and lazily parsed
chapters. This is the "document" layer the reader and plugins talk to.

Positions are { chapter = i, block = j, offset = k } where `offset` is a
byte offset into block.text. Positions compare in reading order.
--]]
local Zip = require("tome.zip")
local xml = require("tome.xml")
local html = require("tome.html")
local util = require("tome.util")

local Epub = {}
Epub.__index = Epub

local function url_decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- Resolve `href` relative to the directory of `base` inside the zip.
local function resolve(base, href)
    href = url_decode(href:gsub("#.*$", ""))
    local dir = base:match("^(.*/)") or ""
    local path = href:sub(1, 1) == "/" and href:sub(2) or dir .. href
    local parts = {}
    for seg in path:gmatch("[^/]+") do
        if seg == ".." then parts[#parts] = nil
        elseif seg ~= "." then parts[#parts + 1] = seg end
    end
    return table.concat(parts, "/")
end

function Epub.open(path)
    local zip, err = Zip.open(path)
    if not zip then return nil, err end
    local self = setmetatable({ path = path, zip = zip, chapters = {}, toc = {}, cache = {} }, Epub)
    local ok, perr = pcall(self._load, self)
    if not ok then zip:close(); return nil, perr end
    return self
end

function Epub:_load()
    local container = self.zip:read("META-INF/container.xml")
    if not container then error("missing META-INF/container.xml") end
    local rootfile = xml.find(xml.parse_tree(container), "rootfile")
    local opf_path = rootfile and rootfile.attrs["full-path"]
    if not opf_path then error("no rootfile in container.xml") end
    local opf_src = self.zip:read(opf_path) or error("missing package document " .. opf_path)
    local opf = xml.parse_tree(opf_src)

    -- Metadata
    local meta = xml.find(opf, "metadata") or opf
    local function dc(name)
        local n = xml.find(meta, name)
        return n and util.trim(xml.text(n)) or nil
    end
    self.title = dc("title") or util.basename(self.path):gsub("%.epub$", "")
    local authors = {}
    for _, n in ipairs(xml.find_all(meta, "creator")) do
        local role = n.attrs.role
        if not role or role == "aut" then authors[#authors + 1] = util.trim(xml.text(n)) end
    end
    self.authors = authors
    self.language = dc("language")

    -- Manifest and spine
    local manifest = {}
    local nav_href, ncx_href
    for _, item in ipairs(xml.find_all(opf, "item")) do
        local a = item.attrs
        if a.id and a.href then
            manifest[a.id] = { href = resolve(opf_path, a.href), type = a["media-type"], props = a.properties or "" }
            if (a.properties or ""):find("nav") then nav_href = manifest[a.id].href end
            if a["media-type"] == "application/x-dtbncx+xml" then ncx_href = manifest[a.id].href end
        end
    end
    local spine = xml.find(opf, "spine")
    if spine and spine.attrs.toc and manifest[spine.attrs.toc] then ncx_href = manifest[spine.attrs.toc].href end

    local total = 0
    for _, ref in ipairs(spine and xml.find_all(spine, "itemref") or {}) do
        local item = manifest[ref.attrs.idref or ""]
        if item and (item.type or ""):find("html") and ref.attrs.linear ~= "no" then
            local entry = self.zip.entries[item.href]
            local size = entry and entry.usize or 1
            self.chapters[#self.chapters + 1] = { href = item.href, size = size, start = total }
            total = total + size
        end
    end
    -- Include non-linear items only if nothing else exists.
    if #self.chapters == 0 then error("EPUB has no readable spine items") end
    self.total_size = total

    local by_href = {}
    for i, ch in ipairs(self.chapters) do by_href[ch.href] = i end

    -- Table of contents: EPUB3 nav first, then NCX.
    local toc = {}
    if nav_href then
        local src = self.zip:read(nav_href)
        if src then
            local tree = xml.parse_tree(src)
            for _, nav in ipairs(xml.find_all(tree, "nav")) do
                local t = nav.attrs["epub:type"] or nav.attrs.type or ""
                if t:find("toc") then
                    local function walk(node, depth)
                        for _, c in ipairs(node.children or {}) do
                            if c.name == "li" then
                                local a = xml.find(c, "a")
                                if a and a.attrs.href then
                                    toc[#toc + 1] = { title = util.trim(xml.text(a):gsub("%s+", " ")), depth = depth,
                                        href = resolve(nav_href, a.attrs.href), fragment = a.attrs.href:match("#(.+)$") }
                                end
                                for _, sub in ipairs(c.children or {}) do
                                    if sub.name == "ol" then walk(sub, depth + 1) end
                                end
                            elseif c.children then
                                walk(c, depth)
                            end
                        end
                    end
                    walk(nav, 1)
                    break
                end
            end
        end
    end
    if #toc == 0 and ncx_href then
        local src = self.zip:read(ncx_href)
        if src then
            local function walk(node, depth)
                for _, c in ipairs(node.children or {}) do
                    if c.name == "navpoint" then
                        local label = xml.find(c, "text")
                        local content = xml.find(c, "content")
                        if content and content.attrs.src then
                            toc[#toc + 1] = { title = label and util.trim(xml.text(label):gsub("%s+", " ")) or "?",
                                depth = depth, href = resolve(ncx_href, content.attrs.src),
                                fragment = content.attrs.src:match("#(.+)$") }
                        end
                        walk(c, depth + 1)
                    elseif c.children and c.name ~= "navpoint" then
                        walk(c, depth)
                    end
                end
            end
            walk(xml.find(xml.parse_tree(src), "navmap") or {}, 1)
        end
    end
    for _, e in ipairs(toc) do e.chapter = by_href[e.href] end
    self.toc = toc

    -- Chapter titles from the TOC (first entry pointing into each chapter).
    for _, e in ipairs(toc) do
        if e.chapter and not self.chapters[e.chapter].title then self.chapters[e.chapter].title = e.title end
    end
end

--- Parsed chapter: { blocks = {...}, ids = {...}, length = total text bytes }
function Epub:chapter(i)
    local c = self.cache[i]
    if c then return c end
    local ch = self.chapters[i]
    if not ch then return nil end
    local src = self.zip:read(ch.href) or ""
    local blocks, ids = html.parse(src)
    local len = 0
    for _, b in ipairs(blocks) do
        b.start = len
        len = len + #b.text + 1
    end
    c = { blocks = blocks, ids = ids, length = len }
    self.cache[i] = c
    if not ch.title then
        for _, b in ipairs(blocks) do
            if b.kind == "h" then ch.title = util.trim(b.text:gsub("%s+", " ")); break end
        end
    end
    return c
end

function Epub:chapter_title(i)
    local ch = self.chapters[i]
    if not ch then return nil end
    if not ch.title then self:chapter(i) end
    return ch.title or ("Section " .. i)
end

--- Drop parsed chapters except those listed, to bound memory on the device.
function Epub:trim_cache(keep)
    for i in pairs(self.cache) do
        if not keep[i] then self.cache[i] = nil end
    end
end

--- Fraction of the book (0..1) at a position, using spine byte sizes as weights.
function Epub:progress(pos)
    local ch = self.chapters[pos.chapter]
    if not ch then return 0 end
    local c = self:chapter(pos.chapter)
    local within = 0
    if c.length > 0 then
        local b = c.blocks[pos.block]
        within = ((b and b.start or c.length) + (pos.offset or 0)) / c.length
    end
    return (ch.start + within * ch.size) / self.total_size
end

function Epub.compare(a, b)
    if a.chapter ~= b.chapter then return a.chapter < b.chapter and -1 or 1 end
    if a.block ~= b.block then return a.block < b.block and -1 or 1 end
    if a.offset ~= b.offset then return a.offset < b.offset and -1 or 1 end
    return 0
end

--- Plain text between two positions (end exclusive), paragraphs separated by
-- blank lines. Either bound may be nil (start / end of book).
function Epub:text_range(from, to)
    from = from or { chapter = 1, block = 1, offset = 0 }
    to = to or { chapter = #self.chapters, block = math.huge, offset = 0 }
    local parts = {}
    for ci = from.chapter, math.min(to.chapter, #self.chapters) do
        local c = self:chapter(ci)
        local b0 = ci == from.chapter and from.block or 1
        local b1 = ci == to.chapter and math.min(to.block, #c.blocks) or #c.blocks
        for bi = b0, b1 do
            local b = c.blocks[bi]
            local t = b.text
            local s = (ci == from.chapter and bi == from.block) and (from.offset or 0) or 0
            local e = #t
            if ci == to.chapter and bi == to.block then e = to.offset or 0 end
            if e > s then
                -- Do not cut through a UTF-8 sequence.
                while e < #t and e > s do
                    local nb = t:byte(e + 1)
                    if nb < 0x80 or nb >= 0xC0 then break end
                    e = e - 1
                end
                local piece = t:sub(s + 1, e)
                if b.kind == "h" then piece = "## " .. piece end
                parts[#parts + 1] = piece
            end
        end
    end
    return table.concat(parts, "\n\n")
end

function Epub:close()
    self.zip:close()
end

return Epub
