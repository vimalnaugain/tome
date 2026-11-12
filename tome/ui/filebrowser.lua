--[[
Library: folders and .epub files, with reading progress for books you have opened.
--]]
local W = require("tome.ui.widgets")
local util = require("tome.util")
local Cover = require("tome.ui.cover")

local FileBrowser = {}

function FileBrowser.new(app, root)
    local view = W.ListView.new({ title = "Library", icons = true })
    local ids = {} -- path -> book id (fingerprint), computed once per session
    view.app = app
    view.root = root
    view.dir = root

    function view:load(dir)
        self.dir = dir
        local items = {}
        local progress = {}
        for _, b in ipairs(app:recent_books()) do progress[b.path] = b end
        if dir ~= self.root then
            items[#items + 1] = { text = "\226\134\144 ..", bold = true, callback = function()
                self:load(util.dirname(dir))
            end }
        end
        for _, e in ipairs(util.list_dir(dir)) do
            local path = dir .. "/" .. e.name
            if e.is_dir and e.name:sub(1, 1) ~= "." and not e.name:match("%.sdr$") then
                items[#items + 1] = { text = e.name .. "/", bold = true, callback = function() self:load(path) end }
            elseif not e.is_dir and e.name:lower():match("%.epub$") then
                ids[path] = ids[path] or util.file_fingerprint(path)
                local id = ids[path]
                local b = progress[path]
                local sub
                if b and app.stats:is_finished(b.id) then sub = "Finished"
                elseif b then sub = string.format("%.0f%% read", (b.percent or 0) * 100) end
                local meta = not b and app.covers:meta(id)
                local title = (b and b.title) or (meta and meta.title) or e.name:gsub("%.[eE][pP][uU][bB]$", "")
                local authors = (b and b.authors) or (meta and meta.authors)
                if not sub and authors and #authors > 0 then sub = table.concat(authors, ", ") end
                items[#items + 1] = { text = title, subtext = sub, book = { id = id, path = path },
                    icon = function(c, x, y, w, h)
                        Cover.draw(app, c, x, y, w, h, { id = id, title = title, authors = authors }, "fill")
                    end,
                    callback = function() app:open_book(path) end }
            end
        end
        self:set_items(items, dir == self.root and "Library" or util.basename(dir))
        -- decode covers in the background; redraw as they become ready
        local books = {}
        for _, it in ipairs(items) do if it.book then books[#books + 1] = it.book end end
        if self.cover_task then self.cover_task.cancel() end
        local new_books = 0
        self.cover_task = app.covers:prepare_all(books, function()
            new_books = new_books + 1
            if self.ui and self.ui:top() == self then self.ui:set_dirty("partial") end
        end, function()
            -- reload once so titles read from the new books show up
            if new_books > 0 and self.dir == dir then self:load(dir) end
        end)
    end


    view:load(root)
    return view
end

return FileBrowser
