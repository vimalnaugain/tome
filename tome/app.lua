--[[
Application shell: owns the device, UI manager, settings, plugins and the
open book. Also the `app` object every plugin receives (docs/PLUGIN_API.md).
--]]
local UI = require("tome.ui.manager")
local W = require("tome.ui.widgets")
local Http = require("tome.http")
local Plugins = require("tome.plugins")
local Font = require("tome.font")
local Stats = require("tome.stats")
local Covers = require("tome.covers")
local util = require("tome.util")
local json = require("tome.json")
local log = require("tome.log")

local App = {}
App.__index = App

--- opts: root (app dir), config (table from config.lua), device ("kindle"|"emulator"|nil=auto)
function App.new(opts)
    local self = setmetatable({}, App)
    self.root = opts.root or "."
    self.config = opts.config or {}
    local cfg = self.config
    Font.set_dir(self.root .. "/fonts")

    local kind = opts.device or cfg.device
    if not kind then
        kind = require("tome.device.kindle").detect() and "kindle" or "emulator"
    end
    if kind == "kindle" then
        self.device = require("tome.device.kindle").new(cfg.kindle or {})
    else
        self.device = require("tome.device.emulator").new(cfg.emulator or {})
    end
    self.data_dir = cfg.data_dir or (self.root .. "/data")
    self.books_dir = cfg.books_dir or (self.device.is_kindle and "/mnt/us/documents" or (self.root .. "/books"))
    util.mkdir_p(self.data_dir .. "/books")
    util.mkdir_p(self.data_dir .. "/plugins")
    self.settings_path = self.data_dir .. "/settings.lua"
    self.settings = util.load_table(self.settings_path) or {}
    for k, v in pairs(cfg.settings or {}) do if self.settings[k] == nil then self.settings[k] = v end end

    self.stats = Stats.open(self.data_dir .. "/stats.lua")
    self.settings.contrast = self.settings.contrast or 0
    self.covers = Covers.new(self)
    self.library = require("tome.library").new(self)
    self.ui = UI.new(self.device)
    if self.settings.rotation and self.settings.rotation ~= 0 then self.ui:set_rotation(self.settings.rotation) end
    if self.settings.contrast ~= 0 then self.ui:set_contrast(self.settings.contrast) end
    self.http = Http.new({ curl = cfg.curl, ca_bundle = cfg.ca_bundle, tmp_dir = cfg.tmp_dir or "/tmp" })
    self.json, self.log, self.util = json, log, util

    self:_setup_power()
    self.plugins = Plugins.new(self)
    for _, dir in ipairs(cfg.plugin_dirs or { self.root .. "/plugins" }) do self.plugins:load_dir(dir) end
    return self
end

------------------------------------------------------------------------------
-- Plugin-facing helpers
------------------------------------------------------------------------------

--- Per-plugin settings: user config (config.lua `plugins.<name>`) as defaults,
-- runtime changes persisted in data/plugins/<name>.lua.
function App:plugin_settings(name)
    local path = self.data_dir .. "/plugins/" .. name .. ".lua"
    local stored = util.load_table(path) or {}
    local defaults = (self.config.plugins or {})[name] or {}
    local s = { config = defaults, path = path }
    function s:get(key, default)
        local v = stored[key]
        if v == nil then v = defaults[key] end
        if v == nil then v = default end
        return v
    end
    function s:set(key, value) stored[key] = value end
    function s:save() util.save_table(path, stored) end
    function s:data_dir()
        local d = util.dirname(path) .. "/" .. name
        util.mkdir_p(d)
        return d
    end
    return s
end

function App:broadcast(event, ...) self.plugins:broadcast(event, ...) end
function App:collect_menu(where, items, ctx) self.plugins:collect_menu(where, items, ctx) end

--- Short toast-style message (tap or timeout dismisses).
function App:notify(text, ms)
    return self.ui:show(W.Dialog.new({ text = text, timeout_ms = ms or 2500 }))
end

--- Full-screen paginated text (markdown-ish: #, ##, -, **bold**).
function App:show_text(opts)
    return self.ui:show(W.TextViewer.new(opts))
end

--- Progress dialog with a Cancel button. Returns a handle: :set_text(s), :close()
function App:show_progress(opts)
    local dlg
    dlg = W.Dialog.new({ title = opts.title, text = opts.text or "Working\226\128\166", dismissable = false,
        buttons = { { text = "Cancel", callback = function() if opts.on_cancel then opts.on_cancel() end end } } })
    self.ui:show(dlg)
    return {
        set_text = function(_, s) dlg:set_text(s) end,
        close = function() self.ui:close(dlg) end,
    }
end

function App:confirm(opts)
    return self.ui:show(W.Dialog.new({ title = opts.title, text = opts.text, buttons = {
        { text = opts.cancel_text or "Cancel", callback = opts.on_cancel },
        { text = opts.ok_text or "OK", primary = true, callback = opts.on_ok },
    } }))
end

--- Pick one of several options. items = { {text=, value=} }, on_choose(value)
function App:choose(opts)
    local view
    local items = {}
    for _, it in ipairs(opts.items) do
        items[#items + 1] = { text = it.text, subtext = it.subtext, marked = it.marked, callback = function()
            self.ui:close(view)
            opts.on_choose(it.value)
        end }
    end
    view = self.ui:show(W.ListView.new({ title = opts.title, items = items }))
    return view
end

--- Run fn as a cooperative task (HTTP calls inside it don't block the UI).
function App:run_task(fn, on_error)
    return self.ui:spawn(fn, on_error)
end

------------------------------------------------------------------------------
-- Books
------------------------------------------------------------------------------

function App:recent_books()
    local list = {}
    for _, e in ipairs(util.list_dir(self.data_dir .. "/books")) do
        local t = util.load_table(self.data_dir .. "/books/" .. e.name)
        if t and t.path and t.last_read and util.file_exists(t.path) then
            t.id = e.name:gsub("%.lua$", "")
            list[#list + 1] = t
        end
    end
    table.sort(list, function(a, b) return a.last_read > b.last_read end)
    return list
end

function App:open_book(path)
    if self.reader then self:close_reader() end
    -- Opening a book from the library or a list: drop those views, so
    -- leaving the book goes straight back home.
    while self.ui:top() and self.ui:top() ~= self.home do self.ui:close(self.ui:top()) end
    local Reader = require("tome.ui.reader")
    local reader, err = Reader.open(self, path)
    if not reader then
        log.error("open failed:", path, err)
        self:notify("Could not open book:\n" .. tostring(err), 5000)
        return
    end
    self.reader = reader
    self.settings.last_book = path
    self:save_settings()
    self.ui:show(reader)
    self.ui:set_dirty("full")
    self:broadcast("ReaderReady", reader)
    -- have the cover ready for the sleep screen
    self.covers:prepare_all({ { path = path, id = reader.book_id } })
end

function App:close_reader()
    local r = self.reader
    if not r then return end
    self:broadcast("ReaderClose", r)
    -- close any overlays above the reader, then the reader itself
    while self.ui:top() and self.ui:top() ~= r do self.ui:close(self.ui:top()) end
    self.ui:close(r)
    r:close()
    self.reader = nil
    self.settings.last_book = nil
    self:save_settings()
    if self.home then self.home:refresh() end
    self.ui:set_dirty("full")
end

function App:save_settings()
    util.save_table(self.settings_path, self.settings)
end

function App:show_library()
    self.ui:show(require("tome.ui.library").new(self))
end

--- Screen orientation (0, 90, 180, 270), remembered across launches.
function App:set_rotation(r)
    self.settings.rotation = r
    self:save_settings()
    self.ui:set_rotation(r)
end

function App:show_main_menu()
    local items = {}
    self:collect_menu("Main", items, nil)
    local orient = {}
    local Rotation = require("tome.device.rotation")
    for _, r in ipairs({ 0, 90, 270, 180 }) do
        orient[#orient + 1] = { text = Rotation.NAMES[r], checked = function() return (self.device.rotation or 0) == r end,
            callback = function() self:set_rotation(r) end }
    end
    table.insert(items, 1, { text = "Library", callback = function() self:show_library() end })
    items[#items + 1] = { text = "Orientation", submenu = orient }
    items[#items + 1] = { text = "Exit Tome", callback = function() self:quit() end }
    self.ui:show(W.Menu.new({ title = "Tome", items = items }))
end

function App:confirm_quit()
    self:confirm({ text = "Exit Tome and return to the Kindle home screen?", ok_text = "Exit",
        on_ok = function() self:quit() end })
end

function App:quit()
    self.ui:quit()
end

------------------------------------------------------------------------------
-- Sleep: cover on the screen while the Kindle is asleep
------------------------------------------------------------------------------

--- The book whose cover goes on the sleep screen: the open one, else the
-- most recent book in progress.
function App:sleep_book()
    if self.reader then
        local r = self.reader
        return { id = r.book_id, path = r.path, title = r.doc.title, authors = r.doc.authors }
    end
    local recent = self:recent_books()
    return recent[1]
end

function App:draw_sleep_screen()
    local d = self.device
    local Canvas = require("tome.canvas")
    local Cover = require("tome.ui.cover")
    local c = Canvas.new(d.phys_w or d.width, d.phys_h or d.height)
    local book = self:sleep_book()
    if book then
        -- make sure the cover is decoded (about a second on a Kindle, once per book)
        if book.id and book.path then pcall(self.covers.prepare, self.covers, book.path, book.id) end
        local mode = (self.settings.sleep_screen == "cover_fill") and "fill" or "fit"
        Cover.draw(self, c, 0, 0, c.w, c.h, book, mode)
    else
        local f = Font.get("serif", "b", math.floor(d.dpi * 0.2))
        c:text(f, "Tome", (c.w - f:width("Tome")) / 2, c.h / 2)
    end
    d:show_physical(c)
end

function App:on_sleep()
    if self.ui.sleeping then return end
    self.ui.sleeping = true
    log.info("going to sleep")
    if self.reader then self.reader:pause() end
    self:broadcast("Suspend")
    if self.device.special_offers then
        -- The lock-screen ad is drawn by the Kindle UI: let it run while asleep.
        if os.getenv("AWESOME_STOPPED") == "yes" then os.execute("killall -CONT awesome") end
        return
    end
    if (self.settings.sleep_screen or "cover") ~= "off" then
        local ok, err = pcall(self.draw_sleep_screen, self)
        if not ok then log.error("sleep screen failed:", err) end
    end
end

function App:on_wake()
    if not self.ui.sleeping then return end
    self.ui.sleeping = false
    self.device:prevent_sleep(true) -- suspend() turned it off
    log.info("waking up")
    self.ui.last_input_ms = self.device:monotonic_ms()
    if self.reader then self.reader:resume() end
    self:broadcast("Resume")
    if self.device.special_offers and os.getenv("AWESOME_STOPPED") == "yes" then
        os.execute("killall -STOP awesome")
        -- the Kindle UI may still be drawing; repaint once it's done
        self.ui:schedule(2500, function() self.ui:set_dirty("full") end)
    end
    self.ui:set_dirty("full")
end

function App:_setup_power()
    local ui, d = self.ui, self.device
    ui.power_handler = function(ev)
        if ev.event == "sleep" then self:on_sleep()
        elseif ev.event == "wake" then self:on_wake()
        elseif ev.event == "button" and not ui.sleeping then
            -- Power button pressed. The Kindle normally goes to sleep by
            -- itself; if it hasn't within 1.5 s, ask it to.
            ui:schedule(1500, function()
                if not ui.sleeping and d.suspend then
                    log.info("power button: system didn't sleep; requesting suspend")
                    d:suspend()
                end
            end)
        end
    end
    ui.last_input_ms = d:monotonic_ms()
    -- Tome keeps the Kindle awake while it runs (the Kindle can't see our
    -- taps), so it does its own idle timeout and then asks the system to
    -- sleep, which in turn brings up the sleep cover.
    ui.idle_check = function()
        local minutes = self.settings.sleep_after_minutes or self.config.sleep_after_minutes or 10
        if minutes <= 0 or ui.sleeping or #ui.tasks > 0 then return end
        local now = d:monotonic_ms()
        if now - ui.last_input_ms > minutes * 60000 then
            ui.last_input_ms = now
            log.info("idle for", minutes, "minutes: suspending")
            if d.suspend then d:suspend() end
        end
    end
end

function App:run(open_path)
    self.device:prevent_sleep(true)
    self.home = self.ui:show(require("tome.ui.home").new(self))
    self:broadcast("AppStart", self)
    local resume = open_path or (self.settings.resume_last ~= false and self.settings.last_book)
    if resume and util.file_exists(resume) then self:open_book(resume) end
    local ok, err = xpcall(function() self.ui:run() end, debug.traceback)
    if not ok then log.error("fatal:", err) end
    if self.reader then self.reader:close() end
    self.stats:save()
    self:broadcast("Exit", self)
    self:save_settings()
    self.device:close()
    return ok
end

return App
