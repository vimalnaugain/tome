--[[
File browser: lists folders and .epub files, plus a "Recently read" entry.
--]]
local W = require("tome.ui.widgets")
local util = require("tome.util")

local FileBrowser = {}

function FileBrowser.new(app, root)
    local view = W.ListView.new({ title = "Library", closable = false })
    view.app = app
    view.root = root
    view.dir = root

    function view:load(dir)
        self.dir = dir
        local items = {}
        if dir ~= self.root then
            items[#items + 1] = { text = "\226\134\144 ..", bold = true, callback = function()
                self:load(util.dirname(dir))
            end }
        else
            local recent = app:recent_books()
            if #recent > 0 then
                items[#items + 1] = { text = "Continue: " .. recent[1].title, bold = true,
                    subtext = string.format("%.0f%% read", (recent[1].percent or 0) * 100),
                    callback = function() app:open_book(recent[1].path) end }
            end
        end
        for _, e in ipairs(util.list_dir(dir)) do
            local path = dir .. "/" .. e.name
            if e.is_dir and e.name:sub(1, 1) ~= "." and not e.name:match("%.sdr$") then
                items[#items + 1] = { text = e.name .. "/", bold = true, callback = function() self:load(path) end }
            elseif not e.is_dir and e.name:lower():match("%.epub$") then
                items[#items + 1] = { text = e.name:gsub("%.[eE][pP][uU][bB]$", ""), callback = function()
                    app:open_book(path)
                end }
            end
        end
        self:set_items(items, dir == self.root and "Library" or util.basename(dir))
    end

    -- The close button on the library exits the app (with confirmation).
    local base_handle = view.handle
    function view:handle(ev)
        if ev.type == "tap" and self.close_rect and W.inside(ev, self.close_rect) then
            app:confirm_quit()
            return true
        end
        if ev.type == "key" and (ev.key == "menu") then
            app:show_main_menu()
            return true
        end
        return base_handle(self, ev)
    end

    view:load(root)
    return view
end

return FileBrowser
