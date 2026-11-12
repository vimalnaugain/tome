--[[
Story recap plugin: "where was I?" for books you put down a while ago.

Reader menu → Recap opens a dialog: [Last one] [Quick] [Full story].
Provider, model and length are set in config.lua.

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

--- One "Recap" entry; it opens a small dialog with the choices.
function RecapPlugin:addToReaderMenu(items, reader)
    table.insert(items, 2, { text = "Recap", callback = function() self:show_dialog(reader) end })
end

function RecapPlugin:show_dialog(reader)
    local W = require("tome.ui.widgets")
    local has_last = util.file_exists(self:_last_recap_path(reader))
    local buttons = {
        { text = "Quick", callback = function() self:run(reader, "quick") end },
        { text = "Full story", primary = true, callback = function() self:story_so_far(reader) end },
    }
    if has_last then table.insert(buttons, 1, { text = "Last one", callback = function() self:show_last(reader) end }) end
    self.app.ui:show(W.Dialog.new({
        title = "Recap",
        text = "A spoiler-free reminder of the story up to this page.\n\nQuick covers the last few pages. Full story covers everything so far.",
        buttons = buttons,
    }))
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
