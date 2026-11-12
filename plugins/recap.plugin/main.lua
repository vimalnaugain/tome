--[[
Story recap plugin: "where was I?" for books you put down a while ago.

Reader menu:
  Recap ▶  Quick recap (recent pages)
           Story so far
           Show last recap
           Provider / Length / Clear cached chapter notes

Configure providers and keys in config.lua (see config.example.lua).
--]]
local util = require("tome.util")

local RecapPlugin = {}

function RecapPlugin:init()
    self.Providers = self:require("providers")
    self.Recap = self:require("recap")
end

function RecapPlugin:_provider()
    local name = self.settings:get("provider")
    if not name then
        local names = self.Providers.names()
        name = names[1]
    end
    if not name then return nil, "No recap provider configured. Add one under plugins.recap.providers in config.lua." end
    return self.Providers.get(name)
end

function RecapPlugin:_last_recap_path(reader)
    return self.settings:data_dir() .. "/" .. reader:book_info().id .. ".last.lua"
end

function RecapPlugin:_show(reader, kind, text)
    local pos = reader:position()
    local title = (kind == "quick" and "Quick recap" or "Story so far") .. string.format(" \194\183 %.0f%%", pos.percent)
    util.save_table(self:_last_recap_path(reader), { kind = kind, text = text, title = title, at = os.time(),
        position = { chapter = pos.chapter, block = pos.block, offset = pos.offset } })
    self.app:show_text({ title = title, text = text })
end

function RecapPlugin:run(reader, kind)
    if self.busy then return end
    local provider, perr = self:_provider()
    if not provider then
        self.app:notify(perr, 6000)
        return
    end
    local progress
    local task
    progress = self.app:show_progress({ title = "Recap", text = "Reading your place in the book\226\128\166",
        on_cancel = function() if task then task.cancel() end end })
    self.busy = true
    local function finish()
        self.busy = false
        progress:close()
        reader.doc:trim_cache({ [reader:position().chapter] = true })
    end
    task = self.app:run_task(function()
        local engine = self.Recap.new({ reader = reader, provider = provider,
            progress = function(msg) progress:set_text(msg) end })
        local text, err
        if kind == "quick" then
            text, err = engine:quick()
        else
            text, err = engine:story_so_far()
        end
        finish()
        if text then
            self:_show(reader, kind, text)
        elseif err ~= "cancelled" then
            self.app:notify("Recap failed:\n" .. tostring(err), 8000)
        end
    end, function(err)
        finish()
        self.app:notify("Recap failed:\n" .. tostring(err), 8000)
    end)
end

--- Full recaps may need one-time chapter notes; confirm when that is a lot.
function RecapPlugin:story_so_far(reader)
    local provider = self:_provider()
    local ok, n, chars = pcall(function()
        if not provider then return 0, 0 end
        local engine = self.Recap.new({ reader = reader, provider = provider })
        return engine:pending_chapter_summaries()
    end)
    reader.doc:trim_cache({ [reader:position().chapter] = true })
    local threshold = self.settings:get("confirm_after_chapters", 6)
    if ok and n and n >= threshold then
        self.app:confirm({
            title = "First recap for this book",
            text = string.format("To recap, %d earlier chapters (about %dk words) need to be summarized once. "
                .. "Later recaps reuse these notes. Continue?", n, math.floor(chars / 6000 + 0.5)),
            ok_text = "Continue",
            on_ok = function() self:run(reader, "full") end,
        })
    else
        self:run(reader, "full")
    end
end

function RecapPlugin:show_last(reader)
    local last = util.load_table(self:_last_recap_path(reader))
    if not last then
        self.app:notify("No recap yet for this book.")
        return
    end
    self.app:show_text({ title = last.title .. " (saved)", text = last.text })
end

function RecapPlugin:addToReaderMenu(items, reader)
    local plugin = self
    local settings_items = function()
        local list = {}
        for _, name in ipairs(self.Providers.names()) do
            local p = self.Providers.get(name)
            list[#list + 1] = { text = "Provider: " .. (p and p.name or name),
                checked = function()
                    local cur = plugin.settings:get("provider") or self.Providers.names()[1]
                    return cur == name
                end,
                callback = function() plugin.settings:set("provider", name); plugin.settings:save() end }
        end
        for _, len in ipairs({ "short", "medium", "long" }) do
            list[#list + 1] = { text = "Length: " .. len,
                checked = function() return plugin.settings:get("length", "medium") == len end,
                callback = function() plugin.settings:set("length", len); plugin.settings:save() end }
        end
        list[#list + 1] = { text = "Clear cached chapter notes", callback = function()
            local provider = plugin:_provider()
            if provider then plugin.Recap.new({ reader = reader, provider = provider }):clear_cache() end
            plugin.app:notify("Chapter notes cleared for this book.")
        end }
        return list
    end
    table.insert(items, 2, { text = "Recap", submenu = function()
        return {
            { text = "Quick recap (recent pages)", callback = function() plugin:run(reader, "quick") end },
            { text = "Story so far", callback = function() plugin:story_so_far(reader) end },
            { text = "Show last recap", callback = function() plugin:show_last(reader) end },
            { text = "Recap settings", submenu = settings_items },
        }
    end })
end

--- Offer a recap when a book is reopened after a break.
function RecapPlugin:onReaderReady(reader)
    local days = self.settings:get("auto_offer_after_days", 3)
    local last = reader:last_read_time()
    if not days or days <= 0 or not last then return end
    local away = (os.time() - last) / 86400
    if away < days then return end
    local pos = reader:position()
    if pos.percent < 1 then return end
    self.app:confirm({
        title = "Welcome back",
        text = string.format("You last read this book %d days ago (%.0f%% in). Want a quick recap?",
            math.floor(away), pos.percent),
        ok_text = "Recap", cancel_text = "Not now",
        on_ok = function() self:run(reader, "quick") end,
    })
end

return RecapPlugin
