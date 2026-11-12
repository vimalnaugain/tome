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
--- os.execute succeeded? (0 in Lua 5.1, true with LuaJIT's 5.2 compat mode)
local function sh_ok(cmd)
    local r = os.execute(cmd)
    return r == 0 or r == true
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
        phys_w = 1072, phys_h = 1448, rotation = 0,
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
    -- landscape: a tap on the physical right edge is at the logical bottom
    k:set_rotation(90)
    eq(k.width, 1448); eq(k.height, 1072)
    k:_handle_events(dev, frame({ A, core.ABS_MT_TRACKING_ID, 9 }, { A, core.ABS_MT_POSITION_X, 4095 }, { A, core.ABS_MT_POSITION_Y, 0 }), 6000, out)
    k:_handle_events(dev, frame({ A, core.ABS_MT_TRACKING_ID, -1 }), 6100, out)
    eq(out[5].x, 0); eq(out[5].y, 0)
end)

test("rotation maps canvas and touches consistently", function()
    local R = require("tome.device.rotation")
    local Canvas = require("tome.canvas")
    local pw, ph = 6, 4
    for _, r in ipairs({ 0, 90, 180, 270 }) do
        local lw, lh = R.dims(pw, ph, r)
        local c = Canvas.new(lw, lh)
        for i = 0, lw * lh - 1 do c.buf[i] = i % 251 end
        local phys = R.to_physical_canvas(c, pw, ph, r)
        for py = 0, ph - 1 do
            for px = 0, pw - 1 do
                local lx, ly = R.to_logical(px, py, pw, ph, r)
                eq(phys.buf[py * pw + px], c.buf[ly * lw + lx], "r=" .. r)
                local bx, by = R.to_physical(lx, ly, pw, ph, r)
                eq(bx, px); eq(by, py)
            end
        end
    end
end)

test("reading stats, speed and time left", function()
    local Stats = require("tome.stats")
    local s = Stats.open(tmp .. "/stats_test.lua")
    eq(math.floor(s:chars_per_minute()), 1100)
    for _ = 1, 40 do s:record("b1", 30, 1000) end   -- 2000 chars/min for 20 min
    assert(math.abs(s:chars_per_minute() - 2000) < 1, "learned speed " .. s:chars_per_minute())
    s:record("b1", 5000, 1000)                      -- away from the device: ignored
    eq(s.data.books.b1.seconds, 40 * 30)
    s:set_finished("b1", true)
    eq(s:year().finished, 1); eq(s:year().seconds, 1200)
    eq(s:streak_days(), 1)
    eq(Stats.format_duration(20), "less than a minute")
    eq(Stats.format_duration(3 * 3600 + 5 * 60), "3 h 05 min")
    -- reader exposes time left consistent with remaining text
    reader:go_to({ chapter = 1, block = 1, offset = 0 })
    local ch_left, book_left = reader:time_left()
    assert(ch_left >= 0 and book_left > ch_left, "book time left should exceed chapter time left")
    eq(math.floor(reader:position().percent), 0)
end)

test("API key files with editor junk are cleaned", function()
    local P = app.plugins.by_name.recap.Providers
    local key = "AIzaSyD-EXAMPLEexample_1234567890abcde"
    for name, raw in pairs({
        plain = key, crlf = key .. "\r\n", bom = "\239\187\191" .. key .. "\n",
        rtf = "{\\rtf1\\ansi\n{\\fonttbl\\f0 Helvetica;}\n\\f0\\fs24 \\cf0 " .. key .. "}",
        quoted = '"' .. key .. '"', assign = "GEMINI_API_KEY=" .. key,
    }) do
        eq(P.clean_key(raw), key, name)
    end
    eq(P.clean_key(" sk-ant-api03-abcDEF_123-xyz456789012345 \n"), "sk-ant-api03-abcDEF_123-xyz456789012345")
end)

test("image decoders match PIL (baseline, progressive, PNG)", function()
    local Image = require("tome.image")
    local ffi = require("ffi")
    local script = [[
import sys, io, random
from PIL import Image, ImageDraw
random.seed(3)
im = Image.new("RGB", (333, 517), (200, 120, 60))
d = ImageDraw.Draw(im)
for i in range(30):
    x, y = random.randint(0, 300), random.randint(0, 480)
    d.ellipse([x, y, x + random.randint(5, 120), y + random.randint(5, 120)], fill=tuple(random.randint(0, 255) for _ in range(3)))
out = sys.argv[1]
im.save(out + "/a.jpg", quality=85)
im.save(out + "/b.jpg", quality=85, progressive=True)
im.save(out + "/c.jpg", quality=85, progressive=True, restart_marker_rows=1, subsampling=0)
im.convert("P").save(out + "/d.png")
im.convert("RGBA").save(out + "/e.png")
for f in "a.jpg b.jpg c.jpg d.png e.png".split():
    open(out + "/" + f + ".ref", "wb").write(Image.open(out + "/" + f).convert("L").tobytes())
]]
    local f = io.open(tmp .. "/mkimg.py", "w"); f:write(script); f:close()
    assert(sh_ok("python3 " .. tmp .. "/mkimg.py " .. tmp), "python failed")
    for _, name in ipairs({ "a.jpg", "b.jpg", "c.jpg", "d.png", "e.png" }) do
        local img, err = Image.decode(io.open(tmp .. "/" .. name, "rb"):read("*a"))
        assert(img, name .. ": " .. tostring(err))
        eq(img.w, 333); eq(img.h, 517)
        local ref = io.open(tmp .. "/" .. name .. ".ref", "rb"):read("*a")
        local diff = 0
        for i = 0, img.w * img.h - 1 do diff = diff + math.abs(img.buf[i] - ref:byte(i + 1)) end
        assert(diff / (img.w * img.h) < 1.0, name .. " differs from PIL by " .. diff / (img.w * img.h))
    end
    local small = Image.resize(Image.decode(io.open(tmp .. "/a.jpg", "rb"):read("*a")), 50, 80)
    eq(small.w, 50); eq(small.h, 80)
end)

test("cover detection in all EPUB styles", function()
    local Epub = require("tome.epub")
    for _, style in ipairs({ "epub3", "meta", "html", "progressive", "none" }) do
        local path = tmp .. "/cov_" .. style .. ".epub"
        assert(sh_ok("python3 tools/make_test_epub.py " .. path .. " 1 " .. style))
        local b = assert(Epub.open(path))
        local p = b:cover_path()
        if style == "none" then eq(p, nil, style) else eq(p, "OEBPS/images/cover.jpg", style) end
        b:close()
    end
end)

test("cover cache and sleep screen", function()
    local util = require("tome.util")
    local covers = app.covers
    local id = util.file_fingerprint(BOOK)
    assert(covers:prepare(BOOK, id), "fixture should have a cover")
    local img = covers:get(id, 100, 150, "fill")
    eq(img.w, 100); eq(img.h, 150)
    local fit = covers:get(id, 300, 300, "fit")
    eq(fit.h, 300); assert(fit.w < 300)
    eq(covers:meta(id).title, "The Lighthouse at Gull's Reach")
    -- a book without a cover is remembered as such
    local none = tmp .. "/cov_none.epub"
    local nid = util.file_fingerprint(none)
    eq(covers:prepare(none, nid), false); assert(covers:has_none(nid))
    -- power button: sleep draws the cover, input is ignored, wake restores
    app:open_book(BOOK)
    local refreshes = app.device.refresh_count
    app.ui:dispatch({ type = "power", event = "sleep" })
    assert(app.ui.sleeping, "should be sleeping")
    eq(app.device.refresh_count, refreshes + 1)
    local c = app.device.canvas
    local dark = 0
    for i = 0, c.w * c.h - 1, 97 do if c.buf[i] < 128 then dark = dark + 1 end end
    assert(dark > (c.w * c.h / 97) * 0.3, "sleep screen should show the (dark) cover")
    local page = app.reader:position().page
    app.ui:dispatch({ type = "tap", x = 900, y = 800 })
    eq(app.reader:position().page, page, "taps while asleep must not turn pages")
    app.ui:dispatch({ type = "power", event = "wake" })
    assert(not app.ui.sleeping)
    reader = app.reader
end)

app.reader:close()
print(string.format("\n%d passed, %d failed", passed, failed))
os.execute("rm -rf " .. tmp)
os.exit(failed == 0 and 0 or 1)
