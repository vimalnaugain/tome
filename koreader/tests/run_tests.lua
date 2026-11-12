--[[
Tests for recap.koplugin, run with LuaJIT outside KOReader:

    luajit koreader/tests/run_tests.lua

KOReader modules are replaced by small fakes (package.preload); the fake
reader serves a generated book so the spoiler boundary can be checked.
Needs lua-cjson for JSON (apt install lua-cjson).
--]]
local here = arg[0]:match("^(.*)/[^/]+$") or "."
package.path = here .. "/../recap.koplugin/?.lua;" .. package.path
package.cpath = "/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;/usr/lib/lua/5.1/?.so;" .. package.cpath

local cjson = require("cjson")

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then
        passed = passed + 1
        print("ok   " .. name)
    else
        failed = failed + 1
        print("FAIL " .. name .. "\n" .. tostring(err))
    end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function has(s, sub, msg)
    if not s:find(sub, 1, true) then error((msg or "") .. ": missing '" .. sub .. "'", 2) end
end
local function hasnt(s, sub, msg)
    if s:find(sub, 1, true) then error((msg or "") .. ": unexpected '" .. sub .. "'", 2) end
end

-- Fake KOReader ---------------------------------------------------------------

local shown = {}         -- widgets passed to UIManager:show
local scheduled = {}
local settings_files = {}

local function class(t)
    t = t or {}
    t.__index = t
    function t:new(o) o = o or {}; setmetatable(o, self); if o.init then o:init() end; return o end
    function t:extend(o) o = o or {}; o.__index = o; return setmetatable(o, self) end
    return t
end

local function fake_settings(data)
    local s = { data = data or {} }
    function s:readSetting(k) return self.data[k] end
    function s:saveSetting(k, v) self.data[k] = v end
    function s:delSetting(k) self.data[k] = nil end
    function s:flush() self.flushed = (self.flushed or 0) + 1 end
    return s
end

package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) shown[#shown + 1] = w end,
        close = function() end,
        scheduleIn = function(_, _, fn) scheduled[#scheduled + 1] = fn end,
    }
end
local function widget(kind)
    return function()
        local W = class({ kind = kind })
        function W:new(o) o = o or {}; o.kind = kind; return setmetatable(o, self) end
        function W:onShowKeyboard() end
        return W
    end
end
package.preload["ui/widget/confirmbox"] = widget("confirm")
package.preload["ui/widget/infomessage"] = widget("info")
package.preload["ui/widget/textviewer"] = widget("textviewer")
package.preload["ui/widget/inputdialog"] = widget("input")
package.preload["ui/widget/container/widgetcontainer"] = function() return class({}) end
package.preload["datastorage"] = function() return { getSettingsDir = function() return "/tmp/fake" end } end
package.preload["luasettings"] = function()
    return { open = function(_, path)
        settings_files[path] = settings_files[path] or fake_settings()
        return settings_files[path]
    end }
end
local actions = {}
package.preload["dispatcher"] = function()
    return { registerAction = function(_, id, a) actions[id] = a end }
end
local online = true
package.preload["ui/network/manager"] = function()
    return {
        willRerunWhenOnline = function(_, cb) if online then return false end; return true end,
        runWhenConnected = function(_, cb) cb() end,
    }
end
local trapper_log = {}
package.preload["ui/trapper"] = function()
    return {
        wrap = function(_, fn) return fn() end,
        info = function(_, t) trapper_log[#trapper_log + 1] = "info:" .. tostring(t); return true end,
        clear = function() end,
        confirm = function(_, text) trapper_log[#trapper_log + 1] = "confirm:" .. text; return true end,
        dismissableRunInSubprocess = function(_, task, msg)
            trapper_log[#trapper_log + 1] = "run:" .. msg
            return true, task()
        end,
    }
end
package.preload["logger"] = function()
    local l = function() end
    return { warn = l, err = l, dbg = l, info = l }
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ffi/util"] = function()
    return {
        template = function(s, ...)
            local args = { ... }
            return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
        end,
        sleep = function() end,
    }
end
package.preload["device"] = function()
    return { screen = { getWidth = function() return 600 end, getHeight = function() return 800 end } }
end
package.preload["json"] = function()
    local J = { encode = cjson.encode, decode = function(s) return cjson.decode(s) end }
    J.decode = setmetatable({ simple = {} }, { __call = function(_, s) return cjson.decode(s) end })
    return J
end

-- A generated book ----------------------------------------------------------

--- Chapters of `size` chars each; every chapter contains a unique marker.
local function make_book(n_chapters, size)
    local chapters, full, starts = {}, {}, {}
    local pos = 1
    for i = 1, n_chapters do
        local head = string.format("CHAPTER-%d-START Café story. ", i)
        local body = head .. string.rep("word ", math.floor((size - #head) / 5))
        chapters[i] = body .. "\n\n"
        starts[i] = pos
        full[#full + 1] = chapters[i]
        pos = pos + #chapters[i]
    end
    return { text = table.concat(full), starts = starts, n = n_chapters }
end

local PAGE = 1000

--- A fake crengine reader UI showing `book` at page `page`.
local function fake_ui(book, page, opts)
    opts = opts or {}
    local text = book.text
    local count = math.ceil(#text / PAGE)
    local function xp(off) return "/body/offset[" .. off .. "]" end
    local function off(x) return tonumber(x:match("%[(%d+)%]")) end
    local doc = { file = "/books/test.epub" }
    function doc:getPageCount() return count end
    function doc:getCurrentPage() return page end
    function doc:getPageXPointer(p) return xp((p - 1) * PAGE + 1) end
    function doc:getTextFromXPointers(a, b)
        doc.max_end = math.max(doc.max_end or 0, off(b) - 1)
        return text:sub(off(a), off(b) - 1)
    end
    function doc:getTextFromPositions()
        -- end of the last word on screen
        return { text = "", pos1 = xp(math.min(page * PAGE, #text) + 1) }
    end
    function doc:clearSelection() end
    local toc_entries = {}
    if not opts.no_toc then
        for i = 1, book.n do
            local o = book.starts[i]
            toc_entries[i] = { title = "Chapter " .. i, depth = 1, xpointer = xp(o),
                page = math.floor((o - 1) / PAGE) + 1 }
        end
    end
    local toc = { toc = toc_entries }
    function toc:fillToc() end
    function toc:getTocTitleByPage(p)
        local t
        for _, e in ipairs(toc_entries) do if e.page <= p then t = e.title end end
        return t
    end
    local ui = {
        document = doc, rolling = {}, toc = toc,
        doc_props = { title = "Test Book", authors = "A. Writer\nB. Writer" },
        doc_settings = fake_settings(opts.doc_data),
        menu = { registerToMainMenu = function(self, p) self.plugin = p end },
    }
    function ui:getCurrentPage() return page end
    return ui
end

--- Fake HTTP: records requests, answers like the Claude API.
local requests = {}
local Providers = require("recap_providers")
local function claude_reply(text, extra)
    local r = { content = { { type = "text", text = text } }, stop_reason = "end_turn" }
    for k, v in pairs(extra or {}) do r[k] = v end
    return cjson.encode(r)
end
local responder
Providers.http_post = function(url, headers, body)
    local req = { url = url, headers = headers, body = cjson.decode(body) }
    requests[#requests + 1] = req
    return responder(req)
end
local function default_responder(req)
    local user = req.body.messages[#req.body.messages].content
    if user:find("Write notes on this chapter", 1, true) then
        local ch = user:match("Chapter: ([^\n]+)")
        return 200, claude_reply("- notes for " .. ch)
    end
    return 200, claude_reply("## The story so far\n**Ann** sails.\n- bullet")
end

local function reset()
    requests, shown, scheduled, trapper_log = {}, {}, {}, {}
    responder = default_responder
    settings_files = {}
end

local function new_plugin(ui, settings)
    package.loaded["main"] = nil
    local Recap = dofile(here .. "/../recap.koplugin/main.lua")
    local p = Recap:new{ ui = ui }
    for k, v in pairs(settings or {}) do p.settings:saveSetting(k, v) end
    return p
end

local function user_text(req) return req.body.messages[#req.body.messages].content end

-- Tests -----------------------------------------------------------------------

local Engine = require("recap_engine")

test("engine: tail and split keep UTF-8 and paragraphs intact", function()
    local s = string.rep("é", 3000) .. "\n" .. string.rep("ü", 10)
    local t = Engine.tail(s, 101)
    assert(t:sub(1, 1) ~= "\xA9" and t:byte(1) ~= 0xBC, "tail starts mid-character")
    local parts = Engine.split(string.rep("é", 5000), 999)
    for _, p in ipairs(parts) do
        local b = p:byte(1)
        assert(b < 0x80 or b >= 0xC0, "piece starts mid-character")
    end
    eq(table.concat(parts), string.rep("é", 5000), "split loses text")
    local para = Engine.split(string.rep("a", 50) .. "\n\n" .. string.rep("b", 50), 40)
    eq(para[1], string.rep("a", 50) .. "\n\n", "split at paragraph")
end)

test("engine: markdown to plain text", function()
    local out = Engine.to_plain("## Where you left off\n**Ann** is on the *boat*.\n- **Bob**: friend\n\n")
    eq(out, "\u{25A0} Where you left off\nAnn is on the *boat*.\n\u{2022} Bob: friend")
end)

test("short book: one request with all text, nothing after the screen", function()
    reset()
    local book = make_book(5, 3000)
    local ui = fake_ui(book, 7) -- page 7 = chapter 3
    local p = new_plugin(ui, { providers = { anthropic = { api_key = "sk-ant-test" } } })
    p:run("full")
    eq(#requests, 1, "requests")
    local req = requests[1]
    eq(req.url, "https://api.anthropic.com/v1/messages")
    eq(req.headers["x-api-key"], "sk-ant-test")
    eq(req.headers["anthropic-version"], "2026-10-21")
    eq(req.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
    eq(req.body.model, "claude-opus-5-5")
    eq(req.body.fallbacks, "default")
    eq(req.body.output_config.effort, "medium")
    local u = user_text(req)
    has(u, "Book: Test Book by A. Writer, B. Writer")
    has(u, "CHAPTER-1-START")
    has(u, "CHAPTER-3-START")
    hasnt(u, "CHAPTER-4-START", "spoiler")
    eq(ui.document.max_end, 7 * PAGE, "text requested past the screen")
    local viewer = shown[#shown]
    eq(viewer.kind, "textviewer")
    has(viewer.title, "Story so far")
    has(viewer.text, "\u{25A0} The story so far")
    has(viewer.text, "Ann sails.")
    eq(ui.doc_settings.data.recap_last.kind, "full")
end)

test("long book: chapter notes once, cached, then reused", function()
    reset()
    local book = make_book(12, 30000) -- 360k chars
    local ui = fake_ui(book, 280)     -- inside chapter 10
    local p = new_plugin(ui, { providers = { anthropic = { api_key = "k" } } })
    p:run("full")
    -- 9 finished chapters → 9 notes + final recap; asked first (>= 6)
    eq(#requests, 10, "requests")
    local confirm = trapper_log[1]:find("confirm:", 1, true) and trapper_log[1] or trapper_log[2]
    has(confirm, "9 earlier chapters")
    local final = user_text(requests[10])
    has(final, "<chapter_notes>")
    has(final, "### Chapter 1\n- notes for Chapter 1")
    has(final, "### Chapter 9")
    hasnt(final, "### Chapter 10", "current chapter must not be summarized")
    hasnt(final, "CHAPTER-11-START", "spoiler")
    eq(requests[1].body.output_config.effort, "low")
    for _, r in ipairs(requests) do
        hasnt(user_text(r), "CHAPTER-11-START", "spoiler in a request")
    end
    assert(ui.document.max_end <= 280 * PAGE, "text requested past the screen")
    local cache = ui.doc_settings.data.recap_notes
    eq(cache.version, 1)
    -- Second recap: no new notes needed.
    requests = {}
    p:run("full")
    eq(#requests, 1, "notes should be reused")
    -- Quick recap reuses the notes too.
    requests = {}
    p:run("quick")
    eq(#requests, 1)
    local q = user_text(requests[1])
    has(q, "### Chapter 9")
    has(q, "## Where you left off")
    eq(requests[1].body.output_config.effort, "low")
    has(shown[#shown].title, "Quick recap")
end)

test("no table of contents: fixed-size parts are summarized", function()
    reset()
    local book = make_book(4, 100000)
    local ui = fake_ui(book, 350, { no_toc = true })
    local p = new_plugin(ui, { providers = { anthropic = { api_key = "k" } }, confirm_after_chapters = 99 })
    p:run("full")
    -- 350k read → 5 parts of 60k, current one excluded → 4 notes + recap
    eq(#requests, 5)
    has(user_text(requests[5]), "### Part 4")
end)

test("errors, refusals and cancellation", function()
    reset()
    local ui = fake_ui(make_book(3, 2000), 3)
    local p = new_plugin(ui)
    p:run("quick")
    eq(#requests, 0, "no key: no request")
    has(shown[#shown].text, "API key")

    p.settings:saveSetting("providers", { anthropic = { api_key = "k" } })
    responder = function() return 200, claude_reply("", { content = {}, stop_reason = "refusal" }) end
    p:run("quick")
    has(shown[#shown].text, "declined")

    local calls = 0
    responder = function() calls = calls + 1; return 529, '{"error":{"message":"Overloaded"}}' end
    p:run("quick")
    eq(calls, 3, "retries")
    has(shown[#shown].text, "HTTP 529: Overloaded")

    responder = function() return 401, '{"error":{"message":"invalid x-api-key"}}' end
    p:run("quick")
    has(shown[#shown].text, "Claude API error 401: invalid x-api-key")

    -- User taps to cancel: no error box.
    local Trapper = require("ui/trapper")
    local orig = Trapper.dismissableRunInSubprocess
    Trapper.dismissableRunInSubprocess = function() return false end
    local before = #shown
    p:run("quick")
    Trapper.dismissableRunInSubprocess = orig
    eq(#shown, before, "cancel should be silent")
    eq(p.busy, false)
end)

test("OpenAI-compatible and Ollama providers", function()
    reset()
    local ui = fake_ui(make_book(3, 2000), 3)
    local p = new_plugin(ui, { provider = "ollama" })
    responder = function(req)
        return 200, cjson.encode({ choices = { { message = { content = "<think>hmm</think>\n## Previously\nok" } } } })
    end
    p:run("quick")
    eq(requests[1].url, "http://192.168.1.20:11434/v1/chat/completions")
    eq(requests[1].body.model, "llama3.1")
    eq(requests[1].body.messages[1].role, "system")
    eq(requests[1].headers.authorization, nil)
    eq(shown[#shown].text, "\u{25A0} Previously\nok")

    requests = {}
    p.settings:saveSetting("provider", "openai")
    p.settings:saveSetting("providers", { openai = { api_key = "sk-x", model = "gpt-test" } })
    p:run("quick")
    eq(requests[1].url, "https://api.openai.com/v1/chat/completions")
    eq(requests[1].headers.authorization, "Bearer sk-x")
end)

test("offer a recap after a break, and remember activity", function()
    reset()
    local ui = fake_ui(make_book(3, 3000), 5, { doc_data = { recap_last_active = os.time() - 5 * 86400 } })
    local p = new_plugin(ui, { providers = { anthropic = { api_key = "k" } } })
    p:onReaderReady()
    eq(#scheduled, 1)
    scheduled[1]()
    local box = shown[#shown]
    eq(box.kind, "confirm")
    has(box.text, "5 days ago")
    box.ok_callback()
    eq(#requests, 1)
    p:onSaveSettings()
    assert(os.time() - ui.doc_settings.data.recap_last_active < 5)

    -- Recently read, or setting off: no offer.
    reset()
    local ui2 = fake_ui(make_book(3, 3000), 5, { doc_data = { recap_last_active = os.time() - 3600 } })
    local p2 = new_plugin(ui2)
    p2:onReaderReady(); scheduled[1]()
    eq(#shown, 0)
    p2.settings:saveSetting("auto_offer_after_days", 0)
    p2.suspended_at = os.time() - 30 * 86400
    p2:onResume(); scheduled[2]()
    eq(#shown, 0)
end)

test("menu, settings and dispatcher actions", function()
    reset()
    local ui = fake_ui(make_book(3, 3000), 5)
    local p = new_plugin(ui)
    assert(actions.recap_quick and actions.recap_full and actions.recap_last, "dispatcher actions")
    local items = {}
    p:addToMainMenu(items)
    eq(items.recap.sorting_hint, "tools")
    local sub = items.recap.sub_item_table_func()
    eq(sub[1].text, "Quick recap")
    eq(sub[3].enabled_func(), false, "no last recap yet")
    local settings = sub[4].sub_item_table
    eq(settings[1].text_func(), "Service: Claude (Anthropic)")
    eq(settings[2].text_func(), "API key: not set")
    settings[2].callback()
    local dlg = shown[#shown]
    eq(dlg.text_type, "password")
    dlg.getInputText = function() return "  sk-ant-new  " end
    dlg.buttons[1][2].callback()
    eq(p:providerConfig().api_key, "sk-ant-new")
    eq(settings[2].text_func(), "API key: set")
    eq(settings[3].text_func(), "Model: claude-opus-5-5")
    settings[1].sub_item_table[3].callback()
    eq(p:providerId(), "ollama")
    eq(settings[4].text_func(), "Server: 192.168.1.20:11434")
    p:onRecapLast()
    has(shown[#shown].text, "No recap yet")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
