# Architecture, and what was learned from KOReader

Tome is a small reader for jailbroken Kindles whose job is to host plugins,
starting with the story recap plugin. It is **not** a KOReader clone: no code
is copied from KOReader (AGPL-3.0). KOReader was studied to learn how a
third-party app takes over a Kindle and how its plugin system is shaped.

KOReader was studied at commit `eb8fe6a3` (2026-11-11), with koreader-base
at its default branch. KOReader is open source, so reading its source was
more direct than binary analysis; REA (the reverse-engineering MCP) targets
closed binaries and wasn't needed here.

## What KOReader does, and what Tome does instead

| Concern | KOReader (where) | Tome |
|---|---|---|
| Runtime | Own LuaJIT + ~40 C libraries (koreader-base) | One static LuaJIT binary + `native/tomecore.c` (~250 lines) |
| Taking over the screen | `platform/kindle/koreader.sh`: disables *pillow* via `lipc-set-prop com.lab126.pillow disableEnablePillow disable`, `SIGSTOP`s `awesome` (clock redraws on FW ≥ 5.7.2), optional `stop lab126_gui` | `platform/kindle/tome.sh`: the same three mechanisms, simplified |
| Drawing | `ffi/framebuffer_mxcfb.lua`: mmap `/dev/fb0` + `MXCFB_SEND_UPDATE` ioctls, with different structs/ioctl numbers per SoC generation (Zelda, Rex, MTK, …) | Render to an 8-bit canvas, write a PNG to `/tmp`, show it with Amazon's own `eips -g` (`-f` to flash). Slower, but needs no per-device ioctl tables |
| Input | `frontend/device/input.lua`, a hard-coded touch device path per model (`/dev/input/event1`, `by-path/...`), per-model coordinate fixes | Probe `/dev/input/event0..9` with `EVIOCGBIT`, scale with `EVIOCGABS` ranges, `EVIOCGRAB` so the Kindle UI ignores our taps; calibration overrides in config |
| Page-turn keys | Per-model `event_map` (104/109 swap meaning between Voyage and Oasis) | Default map + `kindle.keymap` override |
| Text rendering | crengine (C++), MuPDF, FreeType, HarfBuzz | Pure Lua EPUB → blocks → greedy line breaking; fonts pre-rasterized to bitmaps by `tools/bake_fonts.py` (Caladea / Carlito, OFL) |
| Archives | libarchive / zlib via FFI | Pure-Lua inflate + zip reader |
| HTTP | LuaSocket + LuaSec | The firmware's `curl`, run in the background, config passed by file |
| Event loop | `UIManager` with widget tree, refresh queue, scheduled tasks | `tome/ui/manager.lua`: view stack, timers, coroutine tasks |
| Plugins | `plugins/<name>.koplugin/{_meta.lua,main.lua}`, a `WidgetContainer` subclass, `self.ui.menu:registerToMainMenu(self)`, event methods `onXxx` | `plugins/<name>.plugin/{_meta.lua,main.lua}`, plain table, `addToReaderMenu(items, reader)`, event methods `onXxx` (see `PLUGIN_API.md`) |
| Keeping awake | `lipc-set-prop com.lab126.powerd preventScreenSaver 1` | Same |

## Layers

```
main.lua                    args, config.lua, App.new():run()
tome/app.lua                device + UI + settings + plugins + open book; the `app` plugins see
tome/ui/manager.lua         view stack, event loop, timers, coroutine tasks (UI.await)
tome/ui/{home,reader,filebrowser,widgets}.lua
tome/stats.lua              reading time per day/book, learned reading speed, finished books
tome/layout.lua             blocks -> lines -> pages
tome/epub.lua               container.xml, OPF, nav/NCX, lazy chapter parsing, text_range()
tome/{html,xml,zip,inflate}.lua
tome/{font,canvas}.lua      bitmap glyphs, 8-bit canvas, PNG encoder
tome/http.lua, json.lua     curl-based HTTP
tome/device/kindle.lua      fb geometry, eips refresh, evdev input
tome/device/emulator.lua    PNG output + scripted input (tests) or SDL window
tome/device/rotation.lua    logical <-> physical canvas and touch mapping (4 orientations)
native/tomecore.c           open/poll/read evdev, EVIOCGRAB/GABS/GBIT, fb info, clock, kill
```

## Positions

A position is `{chapter, block, offset}`: spine item, paragraph within it,
byte offset into that paragraph's text. Positions survive font changes
(pages are recomputed and the page containing the position is found) and are
what plugins use to get text: `reader:text_range(from, to)`. The recap
plugin only ever asks for text up to `reader:page_end()`, which is what makes
it spoiler-free.

## Progress and time left

Each chapter's text length is measured once in a background task (a few
chapters per UI tick) and stored with the book's state, so "%" is based on
text, not file size. Time left = characters left ÷ reading speed. Speed is
learned from forward page turns that took 3 s to 3 min (characters on the
page ÷ time), blended with ~220 words/min until 10 minutes of data exist.
Similar in spirit to KOReader's statistics plugin, but much smaller.

## Known limits

- EPUB only, no DRM (Kindle's own AZW/KFX books can't be read by any third-party app).
- No images, tables or CSS: text, headings, italics/bold, lists, quotes.
- Latin scripts only in the bundled fonts (Latin-1 + Latin Extended-A).
  Re-bake with another font and ranges in `tools/bake_fonts.py` for more.
- Refresh speed is bounded by `eips` (roughly a few hundred ms per page).
  A direct mxcfb backend would be faster, but needs per-SoC code.
- Not yet tested on hardware; see the README's "First run on a device".
