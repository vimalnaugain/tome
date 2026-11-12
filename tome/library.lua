--[[
Library index: finds every EPUB on the device (no folders to browse) and
keeps what we know about each book in <data_dir>/library.lua, so later
visits only look at new or changed files.

entry = { path, id, size, mtime, added, title, authors }
--]]
local ok_core, core = pcall(require, "tomecore")
local util = require("tome.util")
local log = require("tome.log")

local Library = {}
Library.__index = Library

-- Folders on a Kindle that never hold the user's books.
local DEFAULT_EXCLUDE = { "system", "kmc", "extensions", "tome", ".active_content_sandbox", "koreader" }

function Library.new(app)
    local cfg = app.config
    local self = setmetatable({ app = app }, Library)
    self.roots = cfg.library_roots or { app.device.is_kindle and "/mnt/us" or app.books_dir }
    self.exclude = cfg.library_exclude or DEFAULT_EXCLUDE
    self.path = app.data_dir .. "/library.lua"
    self.index = util.load_table(self.path) or {}
    return self
end

local function file_info(path)
    if ok_core and core.stat then
        local size, mtime = core.stat(path)
        return size, mtime
    end
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:close()
    return size, 0
end

--- List EPUB paths under the roots (hidden and system folders skipped).
function Library:find_files()
    local files = {}
    for _, root in ipairs(self.roots) do
        local prune = { "-name '.*'" }
        for _, d in ipairs(self.exclude) do
            prune[#prune + 1] = "-path " .. util.shell_quote(root .. "/" .. d)
        end
        local cmd = string.format("find %s \\( %s \\) -prune -o -type f -print 2>/dev/null",
            util.shell_quote(root), table.concat(prune, " -o "))
        local p = io.popen(cmd)
        if p then
            for line in p:lines() do
                if line:lower():match("%.epub$") and line ~= root then files[#files + 1] = line end
            end
            p:close()
        end
    end
    return files
end

--- Rescan the device. Fast for unchanged files (one stat each).
-- Returns the number of books.
function Library:scan()
    local t0 = os.clock()
    local seen, changed = {}, false
    for _, path in ipairs(self:find_files()) do
        seen[path] = true
        local size, mtime = file_info(path)
        local e = self.index[path]
        if size and (not e or e.size ~= size or e.mtime ~= mtime) then
            local id = util.file_fingerprint(path)
            local meta = self.app.covers:meta(id) or {}
            self.index[path] = { path = path, id = id, size = size, mtime = mtime,
                added = (e and e.added) or os.time(), title = meta.title, authors = meta.authors }
            changed = true
        end
    end
    for path in pairs(self.index) do
        if not seen[path] then self.index[path] = nil; changed = true end
    end
    if changed then util.save_table(self.path, self.index) end
    local n = 0
    for _ in pairs(self.index) do n = n + 1 end
    log.info(string.format("library: %d books (%.2fs)", n, os.clock() - t0))
    return n
end

--- Fill in titles/authors that became known (covers:prepare reads them).
function Library:refresh_meta()
    local changed = false
    for _, e in pairs(self.index) do
        if not e.title then
            local meta = self.app.covers:meta(e.id)
            if meta then e.title, e.authors, changed = meta.title, meta.authors, true end
        end
    end
    if changed then util.save_table(self.path, self.index) end
end

local function sort_key_title(s)
    s = (s or ""):lower():gsub("^the%s+", ""):gsub("^a%s+", ""):gsub("^an%s+", "")
    return s
end

--- Books with reading state merged in.
-- sort: "recent" | "title" | "author"; filter: "all" | "reading" | "finished" | "new"
function Library:books(sort, filter)
    self:refresh_meta()
    local states = {}
    for _, b in ipairs(self.app:recent_books()) do states[b.id] = b end
    local list = {}
    for _, e in pairs(self.index) do
        local st = states[e.id]
        local finished = self.app.stats:is_finished(e.id)
        local b = {
            path = e.path, id = e.id, added = e.added,
            title = (st and st.title) or e.title or util.basename(e.path):gsub("%.[eE][pP][uU][bB]$", ""),
            authors = (st and st.authors) or e.authors,
            percent = st and st.percent, last_read = st and st.last_read,
            finished = finished,
        }
        b.status = finished and "finished" or (st and "reading" or "new")
        if filter == nil or filter == "all" or filter == b.status then list[#list + 1] = b end
    end
    sort = sort or "recent"
    table.sort(list, function(a, b)
        if sort == "title" then
            return sort_key_title(a.title) < sort_key_title(b.title)
        elseif sort == "author" then
            local aa = (a.authors and a.authors[1] or "~"):lower()
            local ba = (b.authors and b.authors[1] or "~"):lower()
            if aa ~= ba then return aa < ba end
            return sort_key_title(a.title) < sort_key_title(b.title)
        end
        -- recent: last opened first, then newest additions
        local ar, br = a.last_read or 0, b.last_read or 0
        if ar ~= br then return ar > br end
        if (a.added or 0) ~= (b.added or 0) then return (a.added or 0) > (b.added or 0) end
        return sort_key_title(a.title) < sort_key_title(b.title)
    end)
    return list
end

function Library:count()
    local n = 0
    for _ in pairs(self.index) do n = n + 1 end
    return n
end

return Library
