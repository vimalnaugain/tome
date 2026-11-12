--[[--
Story recap: "where was I?" for books you put down a while ago.

Reader menu → Tools (🛠) → Recap:
  Quick recap        the last pages, plus any chapter notes already made
  Story so far       everything read so far; long books are summarized
                     chapter by chapter once, and those notes are kept
  Show last recap    reread the previous one without a network call
  Settings           service, API key, model, length, auto-offer

It also offers a quick recap when you come back to a book after a few days,
and adds "Recap" actions for gestures and the dispatcher.

Nothing past the end of the current screen is ever sent to the model.

@module koplugin.recap
--]]
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

-- Loaded now: the plugin folder is only on package.path while main.lua loads.
local Book = require("recap_book")
local Engine = require("recap_engine")
local Providers = require("recap_providers")

local DEFAULTS = {
    provider = "anthropic",
    providers = {
        anthropic = { type = "anthropic", model = Providers.DEFAULT_CLAUDE_MODEL },
        openai = { type = "openai", base_url = "https://api.openai.com/v1" },
        ollama = { type = "ollama", base_url = "http://192.168.1.20:11434/v1", model = "llama3.1" },
    },
    length = "medium",              -- "short" | "medium" | "long"
    auto_offer_after_days = 3,      -- offer a quick recap when reopening a book after N days (0 = off)
    effort = "medium",              -- Claude effort for full recaps
    single_pass_chars = 200000,     -- up to this much text read: one request with all of it
    recent_chars = 12000,           -- verbatim recent text added to a full recap
    quick_recent_chars = 15000,     -- text used by a quick recap
    chunk_chars = 120000,           -- very long chapters are summarized in parts of this size
    confirm_after_chapters = 6,     -- ask before summarizing this many chapters at once
}

local Recap = WidgetContainer:extend{
    name = "recap",
    is_doc_only = true,
}

function Recap:init()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/recap.lua")
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Recap:onDispatcherRegisterActions()
    Dispatcher:registerAction("recap_quick", { category = "none", event = "RecapQuick",
        title = _("Recap: quick"), reader = true })
    Dispatcher:registerAction("recap_full", { category = "none", event = "RecapFull",
        title = _("Recap: story so far"), reader = true })
    Dispatcher:registerAction("recap_last", { category = "none", event = "RecapLast",
        title = _("Recap: show last"), reader = true })
end

-- Settings --------------------------------------------------------------

function Recap:get(key, default)
    local v = self.settings:readSetting(key)
    if v == nil then v = DEFAULTS[key] end
    if v == nil then v = default end
    return v
end

function Recap:set(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
end

function Recap:providerId()
    return self:get("provider")
end

--- Config table of the selected provider (defaults filled in).
function Recap:providerConfig(id)
    id = id or self:providerId()
    local all = self.settings:readSetting("providers") or {}
    local cfg = {}
    for k, v in pairs(DEFAULTS.providers[id] or {}) do cfg[k] = v end
    for k, v in pairs(all[id] or {}) do cfg[k] = v end
    if not cfg.type then cfg.type = DEFAULTS.providers[id] and DEFAULTS.providers[id].type or id end
    return cfg
end

function Recap:setProviderValue(key, value)
    local id = self:providerId()
    local all = self.settings:readSetting("providers") or {}
    all[id] = all[id] or {}
    if value == "" then value = nil end
    all[id][key] = value
    self:set("providers", all)
end

-- Per-book state, kept in the book's sidecar (.sdr) -----------------------

function Recap:bookCache()
    if not self.cache then
        self.cache = self.ui.doc_settings:readSetting("recap_notes") or {}
    end
    return self.cache
end

function Recap:saveBookCache()
    self.ui.doc_settings:saveSetting("recap_notes", self.cache)
    self.ui.doc_settings:flush()
end

-- Running a recap ---------------------------------------------------------

function Recap:run(kind)
    if self.busy then return end
    local provider, err = Providers.build(self:providerConfig())
    if not provider then
        UIManager:show(InfoMessage:new{ text = err })
        return
    end
    local cfg = self:providerConfig()
    if cfg.type == "anthropic" and not (cfg.api_key or cfg.api_key_file) then
        UIManager:show(InfoMessage:new{ text = _("Add your Claude API key first: Recap → Settings → API key.") })
        return
    end
    local function go()
        Trapper:wrap(function() self:_run(kind, provider) end)
    end
    if cfg.type == "ollama" then
        -- A server on the local network: Wi-Fi is enough, no Internet needed.
        NetworkMgr:runWhenConnected(go)
    elseif not NetworkMgr:willRerunWhenOnline(go) then
        go()
    end
end

function Recap:_run(kind, provider)
    self.busy = true
    local ok, err = xpcall(function() self:_runWrapped(kind, provider) end, debug.traceback)
    self.busy = false
    Trapper:clear()
    if not ok then
        logger.err("recap: failed", err)
        UIManager:show(InfoMessage:new{ text = _("Recap failed:") .. "\n" .. tostring(err):match("^[^\n]*") })
    end
end

function Recap:_runWrapped(kind, provider)
    Trapper:info(_("Reading your place in the book…"))
    local message = _("Writing your recap…")
    local engine = Engine.new{
        book = Book.new(self.ui),
        model = provider.model,
        get = function(key, default) return self:get(key, default) end,
        cache = self:bookCache(),
        save_cache = function() self:saveBookCache() end,
        progress = function(msg) message = msg; return true end,
        complete = function(system, user, opts)
            Trapper:clear()
            local completed, res = Trapper:dismissableRunInSubprocess(function()
                local text, cerr = provider.complete(system, user, opts)
                return { text = text, err = cerr }
            end, message .. "\n\n" .. _("Tap to cancel."))
            if not completed then return nil, "cancelled" end
            if type(res) ~= "table" then return nil, _("No response.") end
            return res.text, res.err
        end,
    }

    if kind == "full" then
        local n, chars = engine:pending()
        if n >= self:get("confirm_after_chapters") then
            local go = Trapper:confirm(T(_("To recap, %1 earlier chapters (about %2k words) need to be summarized once. Later recaps reuse these notes.\n\nContinue?"),
                n, math.floor(chars / 6000 + 0.5)), _("Cancel"), _("Continue"))
            if not go then return end
        end
    end

    local text, err
    if kind == "quick" then
        text, err = engine:quick()
    else
        text, err = engine:story_so_far()
    end
    Trapper:clear()
    if not text then
        if err ~= "cancelled" then
            UIManager:show(InfoMessage:new{ text = _("Recap failed:") .. "\n" .. tostring(err) })
        end
        return
    end
    local pos = engine.book:position()
    local title = (kind == "quick" and _("Quick recap") or _("Story so far"))
        .. string.format(" · %.0f%%", pos.percent)
    self.ui.doc_settings:saveSetting("recap_last", { kind = kind, text = text, title = title, at = os.time() })
    self.ui.doc_settings:flush()
    self:show(title, text)
end

function Recap:show(title, text)
    UIManager:show(TextViewer:new{
        title = title,
        text = Engine.to_plain(text),
        text_type = "book_info",
    })
end

function Recap:showLast()
    local last = self.ui.doc_settings:readSetting("recap_last")
    if not last then
        UIManager:show(InfoMessage:new{ text = _("No recap yet for this book.") })
        return
    end
    self:show(last.title .. " " .. _("(saved)"), last.text)
end

function Recap:onRecapQuick() self:run("quick"); return true end
function Recap:onRecapFull() self:run("full"); return true end
function Recap:onRecapLast() self:showLast(); return true end

-- Offer a recap after a break ---------------------------------------------

function Recap:maybeOffer(last_active)
    local days = tonumber(self:get("auto_offer_after_days")) or 0
    if days <= 0 or not last_active then return end
    local away = (os.time() - last_active) / 86400
    if away < days then return end
    local percent = Book.new(self.ui):position().percent
    if percent < 1 then return end
    UIManager:show(ConfirmBox:new{
        text = T(_("You last read this book %1 days ago (%2% in). Want a quick recap?"),
            math.floor(away), string.format("%.0f", percent)),
        ok_text = _("Recap"),
        cancel_text = _("Not now"),
        ok_callback = function() self:run("quick") end,
    })
end

function Recap:onReaderReady()
    local last = self.ui.doc_settings:readSetting("recap_last_active")
    -- Let the page render first.
    UIManager:scheduleIn(1, function() self:maybeOffer(last) end)
end

function Recap:onSaveSettings()
    self.ui.doc_settings:saveSetting("recap_last_active", os.time())
end

function Recap:onSuspend()
    self.suspended_at = os.time()
end

function Recap:onResume()
    local at = self.suspended_at
    self.suspended_at = nil
    if at then UIManager:scheduleIn(1, function() self:maybeOffer(at) end) end
end

-- Menu ----------------------------------------------------------------------

function Recap:editValue(title, key, opts)
    opts = opts or {}
    local cfg = self:providerConfig()
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = opts.secret and "" or (cfg[key] or ""),
        input_hint = opts.hint,
        description = opts.description,
        text_type = opts.secret and "password" or nil,
        buttons = { {
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Save"), is_enter_default = true, callback = function()
                local v = dialog:getInputText():gsub("^%s+", ""):gsub("%s+$", "")
                if not (opts.secret and v == "") then self:setProviderValue(key, v) end
                UIManager:close(dialog)
                if opts.on_done then opts.on_done() end
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Recap:settingsMenu()
    local items = {}
    local services = {}
    for __, t in ipairs(Providers.TYPES) do
        services[#services + 1] = {
            text = t.text,
            checked_func = function() return self:providerId() == t.id end,
            radio = true,
            callback = function() self:set("provider", t.id) end,
        }
    end
    items[#items + 1] = {
        text_func = function()
            for __, t in ipairs(Providers.TYPES) do
                if t.id == self:providerId() then return T(_("Service: %1"), t.text) end
            end
            return _("Service")
        end,
        sub_item_table = services,
    }
    items[#items + 1] = {
        text_func = function()
            local cfg = self:providerConfig()
            local set = (cfg.api_key and cfg.api_key ~= "") or cfg.api_key_file
            return set and _("API key: set") or _("API key: not set")
        end,
        keep_menu_open = true,
        callback = function(touchmenu)
            self:editValue(_("API key"), "api_key", { secret = true,
                description = _("Stored in koreader/settings/recap.lua on this device. Leave empty to keep the current key."),
                hint = self:providerId() == "anthropic" and "sk-ant-…" or "",
                on_done = function() if touchmenu then touchmenu:updateItems() end end })
        end,
        hold_callback = function(touchmenu)
            self:setProviderValue("api_key", "")
            if touchmenu then touchmenu:updateItems() end
            UIManager:show(InfoMessage:new{ text = _("API key removed."), timeout = 2 })
        end,
        help_text = _("Long-press to remove the key."),
    }
    items[#items + 1] = {
        text_func = function() return T(_("Model: %1"), self:providerConfig().model or _("not set")) end,
        keep_menu_open = true,
        callback = function(touchmenu)
            self:editValue(_("Model"), "model", { hint = self:providerId() == "anthropic"
                and Providers.DEFAULT_CLAUDE_MODEL or "llama3.1",
                on_done = function() if touchmenu then touchmenu:updateItems() end end })
        end,
    }
    items[#items + 1] = {
        text_func = function()
            local url = self:providerConfig().base_url
            return T(_("Server: %1"), url and url:match("//([^/]+)") or _("default"))
        end,
        keep_menu_open = true,
        callback = function(touchmenu)
            self:editValue(_("Server address"), "base_url", {
                on_done = function() if touchmenu then touchmenu:updateItems() end end,
                hint = self:providerId() == "anthropic" and "https://api.anthropic.com" or "http://192.168.1.20:11434/v1",
                description = _("Leave empty for the service's default. For Ollama or LM Studio use the computer's address on your Wi-Fi, ending in /v1."),
            })
        end,
        separator = true,
    }
    local lengths = {}
    for __, l in ipairs({ { "short", _("Short (about 120 words)") }, { "medium", _("Medium (about 300 words)") },
                         { "long", _("Long (about 600 words)") } }) do
        lengths[#lengths + 1] = {
            text = l[2], radio = true,
            checked_func = function() return self:get("length") == l[1] end,
            callback = function() self:set("length", l[1]) end,
        }
    end
    items[#items + 1] = { text = _("Recap length"), sub_item_table = lengths }
    local offers = {}
    for __, d in ipairs({ 0, 1, 2, 3, 7, 14, 30 }) do
        offers[#offers + 1] = {
            text = d == 0 and _("Never") or T(_("After %1 days away"), d), radio = true,
            checked_func = function() return tonumber(self:get("auto_offer_after_days")) == d end,
            callback = function() self:set("auto_offer_after_days", d) end,
        }
    end
    items[#items + 1] = { text = _("Offer a recap when I come back"), sub_item_table = offers, separator = true }
    items[#items + 1] = {
        text = _("Forget this book's chapter notes"),
        keep_menu_open = true,
        callback = function()
            UIManager:show(ConfirmBox:new{
                text = _("Delete the chapter notes saved for this book? The next full recap will summarize earlier chapters again."),
                ok_text = _("Delete"),
                ok_callback = function()
                    self.cache = {}
                    self:saveBookCache()
                    self.ui.doc_settings:delSetting("recap_last")
                end,
            })
        end,
    }
    return items
end

function Recap:addToMainMenu(menu_items)
    menu_items.recap = {
        text = _("Recap"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return {
                {
                    text = _("Quick recap"),
                    help_text = _("A short reminder of the last few pages."),
                    callback = function() self:run("quick") end,
                },
                {
                    text = _("Story so far"),
                    help_text = _("Everything up to this page. Long books are summarized chapter by chapter once; later recaps reuse those notes."),
                    callback = function() self:run("full") end,
                },
                {
                    text = _("Show last recap"),
                    enabled_func = function() return self.ui.doc_settings:readSetting("recap_last") ~= nil end,
                    callback = function() self:showLast() end,
                    separator = true,
                },
                { text = _("Settings"), sub_item_table = self:settingsMenu() },
            }
        end,
    }
end

return Recap
