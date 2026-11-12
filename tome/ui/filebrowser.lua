--[[
Library: folders and .epub files, with reading progress for books you have opened.
--]]
local W = require("tome.ui.widgets")
local util = require("tome.util")

local FileBrowser = {}

function FileBrowser.new(app, root)
    local view = W.ListView.new({ title = "Library" })
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
                local b = progress[path]
                local sub
                if b and app.stats:is_finished(b.id) then sub = "Finished"
                elseif b then sub = string.format("%.0f%% read", (b.percent or 0) * 100) end
                items[#items + 1] = { text = (b and b.title) or e.name:gsub("%.[eE][pP][uU][bB]$", ""), subtext = sub,
                    callback = function() app:open_book(path) end }
            end
        end
        self:set_items(items, dir == self.root and "Library" or util.basename(dir))
    end


    view:load(root)
    return view
end

return FileBrowser
