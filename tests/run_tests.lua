--[[
Unit/integration tests. Run from the repo root:
  luajit tests/run_tests.lua
Needs native/tomecore.so (make -C native) and tests/fixtures/gulls_reach.epub
(python3 tools/make_test_epub.py tests/fixtures/gulls_reach.epub).
--]]
package.path = "./?.lua;" .. package.path
package.cpath = "./native/?.so;" .. package.cpath

local passed, failed = 0, 0
local function test(name, fn)
    local ok, err = xpcall(fn, debug.traceback)
    if ok then passed = passed + 1; print("ok   " .. name)
    else failed = failed + 1; print("FAIL " .. name .. "\n" .. tostring(err)) end
end
local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

local tmp = os.getenv("TOME_TEST_TMP") or ("/tmp/tome_tests_" .. os.time())
os.execute("rm -rf " .. tmp .. " && mkdir -p " .. tmp .. "/books")
os.execute("cp tests/fixtures/gulls_reach.epub " .. tmp .. "/books/")
local BOOK = tmp .. "/books/gulls_reach.epub"

test("json round trip", function()
    local json = require("tome.json")
    local v = { a = { 1, 2, 3 }, s = "quote\" nl\n \226\128\148", n = 1.5, t = true, z = json.null }
    local s = json.encode(v)
    local back = assert(json.decode(s))
    eq(back.a[3], 3); eq(back.s, v.s); eq(back.n, 1.5); eq(back.t, true); eq(back.z, json.null)
    eq(json.decode('"\\u00e9\\ud83d\\ude00"'), "\195\169\240\159\152\128")
    eq(json.decode("{bad"), nil)
end)

test("inflate matches zlib", function()
    local inflate = require("tome.inflate")
    local p = io.popen("python3 -c \"import zlib,sys; d=(b'The lamp has gone out. ' * 500) + bytes(range(256)); sys.stdout.buffer.write(zlib.compress(d, 9))\"")
    local z = p:read("*a"); p:close()
    local out = inflate.zlib_inflate(z)
    eq(#out, 23 * 500 + 256)
    eq(out:sub(1, 22), "The lamp has gone out.")
end)

test("epub metadata, toc and text", function()
    local Epub = require("tome.epub")
    local b = assert(Epub.open(BOOK))
    eq(b.title, "The Lighthouse at Gull's Reach")
    eq(#b.chapters, 6); eq(#b.toc, 6)
    eq(b:chapter_title(4), "Chapter 4: Locker No. 7")
    local all = b:text_range()
    assert(not all:find("footnote must not appear"), "footnotes leaked into text")
    assert(all:find("Come home,", 1, true), "italic text missing")
    local part = b:text_range(nil, { chapter = 2, block = 2, offset = 10 })
    assert(not part:find("brass key", 1, true), "text past the end bound")
    b:close()
end)

test("layout paginates long chapters", function()
    local Font = require("tome.font"); Font.set_dir("fonts")
    local Layout = require("tome.layout")
    local blocks = {}
    for i = 1, 60 do
        local t = ("Paragraph " .. i .. " ") .. string.rep("lorem ipsum dolor sit amet ", 12)
        blocks[i] = { kind = "p", runs = { { text = t, style = "r" } }, text = t }
    end
    local l = Layout.new({ width = 600, height = 800, margin_x = 30, margin_top = 30, margin_bottom = 60, font_size = 22 })
    local pages = l:paginate({ blocks = blocks })
    assert(#pages > 5, "expected many pages, got " .. #pages)
    -- pages are contiguous and every line fits
    for i = 2, #pages do
        local prev, cur = pages[i - 1], pages[i]
        eq(prev.last.block, cur.first.block); eq(prev.last.offset, cur.first.offset)
        for _, line in ipairs(cur.lines) do assert(line.top + line.height <= 800 - 60, "line overflows page") end
    end
    eq(Layout.find_page(pages, pages[4].first.block, pages[4].first.offset), 4)
end)

-- App + reader + recap plugin with a fake (synchronous) provider.
local config = {
    data_dir = tmp .. "/data", books_dir = tmp .. "/books", tmp_dir = tmp,
    emulator = { out_dir = tmp .. "/out", script = "/dev/null" },
    plugins = { recap = { single_pass_chars = 1000, confirm_after_chapters = 99,
        providers = { fake = { type = "openai", model = "x" } } } },
}
local App = require("tome.app")
local app = App.new({ root = ".", config = config, device = "emulator" })
app:open_book(BOOK)
local reader = app.reader

test("reader navigation and saved position", function()
    assert(reader, "book did not open")
    reader:go_to({ chapter = 4, block = 1, offset = 0 })
    local pos = reader:position()
    eq(pos.chapter, 4)
    reader:next_page()
    eq(reader:position().chapter, 5)
    reader:prev_page()
    eq(reader:position().chapter, 4)
    local state = require("tome.util").load_table(reader.state_path)
    eq(state.position.chapter, 4)
end)

test("recap: chapter notes, cache and spoiler boundary", function()
    local plugin = app.plugins.by_name.recap
    assert(plugin, "recap plugin not loaded")
    reader:go_to({ chapter = 4, block = 1, offset = 0 })
    local calls = {}
    local fake = { name = "fake", model = "fake-1", complete = function(system, user)
        calls[#calls + 1] = user
        return "summary " .. #calls
    end }
    local engine = plugin.Recap.new({ reader = reader, provider = fake })
    local n = engine:pending_chapter_summaries()
    eq(n, 3, "chapters needing notes")
    local text = assert(engine:story_so_far())
    eq(#calls, 4, "3 chapter notes + 1 recap")
    for _, u in ipairs(calls) do
        assert(not u:find("Tobias surrendered", 1, true), "chapter 5 text leaked into a prompt")
        assert(not u:find("signed the papers", 1, true), "chapter 6 text leaked into a prompt")
        assert(not u:find("<script", 1, true))
    end
    assert(calls[4]:find("<chapter_notes>", 1, true) and calls[4]:find("locker number seven", 1, true),
        "final prompt should hold notes plus recent verbatim text")
    eq(text, "summary 4")
    -- Second recap reuses cached notes: only one new call.
    local engine2 = plugin.Recap.new({ reader = reader, provider = fake })
    eq(engine2:pending_chapter_summaries(), 0)
    engine2:story_so_far()
    eq(#calls, 5)
    -- Quick recap: one call, recent text only up to current page.
    engine2:quick()
    eq(#calls, 6)
    assert(calls[6]:find("<most_recent_pages>", 1, true))
end)

test("canvas png is valid", function()
    local Canvas = require("tome.canvas")
    local c = Canvas.new(300, 238)
    local png = c:to_png()
    local f = io.open(tmp .. "/t.png", "wb"); f:write(png); f:close()
    local p = io.popen("python3 -c \"from PIL import Image; im=Image.open('" .. tmp .. "/t.png'); im.load(); print(im.size, im.mode)\" 2>&1")
    local out = p:read("*a"); p:close()
    assert(out:find("(300, 238) L", 1, true), "PIL could not read our PNG: " .. out)
end)

test("kindle evdev touch parsing", function()
    local core = require("tomecore")
    local Kindle = require("tome.device.kindle")
    local Gestures = require("tome.device.gestures")
    local k = setmetatable({ config = { touch_mirror_x = false }, width = 1072, height = 1448,
        keymap = { [104] = "next" }, gestures = Gestures.new({ tap_slop = 30 }) }, Kindle)
    -- Touch panel reports 0..4095 on both axes (like the Kindle Touch).
    local dev = { touch = true, mt = true, xmin = 0, xmax = 4095, ymin = 0, ymax = 4095, state = { x = 0, y = 0 } }
    local A, S, K = core.EV_ABS, core.EV_SYN, core.EV_KEY
    local function frame(...) local e = { ... }; e[#e + 1] = { S, core.SYN_REPORT, 0 }; return e end
    local out = {}
    -- tap at the right-hand side (protocol B: tracking id, position, then lift)
    k:_handle_events(dev, frame({ A, core.ABS_MT_TRACKING_ID, 7 }, { A, core.ABS_MT_POSITION_X, 3800 }, { A, core.ABS_MT_POSITION_Y, 2000 }), 1000, out)
    k:_handle_events(dev, frame({ A, core.ABS_MT_TRACKING_ID, -1 }), 1100, out)
    eq(#out, 1); eq(out[1].type, "tap")
    assert(math.abs(out[1].x - 994) <= 1, "x scaled: " .. out[1].x)
    -- swipe left
    k:_handle_events(dev, frame({ A, core.ABS_MT_TRACKING_ID, 8 }, { A, core.ABS_MT_POSITION_X, 3500 }, { A, core.ABS_MT_POSITION_Y, 2000 }), 2000, out)
    k:_handle_events(dev, frame({ A, core.ABS_MT_POSITION_X, 2000 }), 2050, out)
    k:_handle_events(dev, frame({ A, core.ABS_MT_POSITION_X, 500 }), 2100, out)
    k:_handle_events(dev, frame({ A, core.ABS_MT_TRACKING_ID, -1 }), 2150, out)
    eq(out[2].type, "swipe"); eq(out[2].dir, "left")
    -- long press via single-touch BTN_TOUCH
    k:_handle_events(dev, frame({ K, core.BTN_TOUCH, 1 }, { A, core.ABS_X, 100 }, { A, core.ABS_Y, 100 }), 3000, out)
    k:_handle_events(dev, frame({ K, core.BTN_TOUCH, 0 }), 4000, out)
    eq(out[3].type, "hold")
    -- page-turn key on a key device
    k:_handle_events({ keys = true, state = {} }, { { K, 104, 1 }, { K, 104, 0 } }, 5000, out)
    eq(out[4].type, "key"); eq(out[4].key, "next"); eq(#out, 4)
end)

app.reader:close()
print(string.format("\n%d passed, %d failed", passed, failed))
os.execute("rm -rf " .. tmp)
os.exit(failed == 0 and 0 or 1)
