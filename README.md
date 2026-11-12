# Tome

A small EPUB reader for jailbroken Kindles, built to host plugins. Its first
plugin is **Story recap**: a spoiler-free "previously on…" of the book you are
reading, written by an LLM (Claude, any OpenAI-compatible API, or a local
Ollama) from the pages you have already read.

Tome borrows ideas, not code, from [KOReader](https://github.com/koreader/koreader):
how to take over the Kindle screen and input, and the folder-per-plugin layout.
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Features

- **Home screen**: the book you're reading (typographic cover, progress bar, % and time left,
  current chapter, "Continue reading"), other books in progress, and your stats: books finished
  this year (tap for the list), reading time this year, days in a row
- **Reading**: EPUB 2/3 (DRM-free) with table of contents, italics/bold, headings, quotes, lists
- **Display**: three typefaces (Caladea, Charter, Carlito), 7 sizes, line spacing, margins
  (narrow/medium/wide), and portrait/landscape in both directions
- **Progress**: a thin progress bar with chapter marks; tap it to cycle between
  *time left in chapter · %*, *page in chapter · time left in book*, *clock · battery*, and bar only.
  Time left is based on your own reading speed, learned as you read
- **Covers**: the EPUB's own cover (JPEG, including progressive, or PNG) on the home screen and as
  thumbnails in the library, with a typographic tile for books without one
- **Sleep screen**: press the power button (or leave the Kindle idle for 10 minutes) and the cover
  of the book you're reading fills the screen, like the Kindle's "show book cover" option. On Kindles
  with ads ("Special Offers"), the Kindle draws its ad there instead
- **Library** with titles, authors, covers and reading progress; "Mark as finished" in the reader menu
- **Controls**: tap right/left (or swipe, or page buttons) to turn pages, tap the top for the menu
- **Plugins** with menus, page events and background HTTP tasks ([docs/PLUGIN_API.md](docs/PLUGIN_API.md))
- **Recap plugin**: menu → **Recap** → *Quick* (the last pages) or *Full story* (everything so far;
  long books are summarized chapter by chapter once and cached), or *Last one* to reread the
  previous recap. It offers a recap when you reopen a book after a few days, and never sends text
  past the end of the current page

The recap plugin is also available for **KOReader**: see [koreader/README.md](koreader/README.md).

## Requirements

- A jailbroken Kindle with KUAL, firmware 5.x, touchscreen (Paperwhite, Oasis, Basic, Voyage, Scribe…)
- An API key for Claude or another provider, or an Ollama server on your network

## Build

The Kindle binary is a static LuaJIT with Tome's C module linked in, cross-compiled with Zig:

```bash
pip install ziglang
```

```bash
ZIG="python3 -m ziglang" tools/build_kindle.sh
```

```bash
tools/package_kindle.sh
```

This produces `build/tome-kindle.zip`.

## Install with KPM (no KUAL needed)

If your Kindle has the Kindle Package Manager (KPM, included with current
jailbreaks), Tome installs like KOReader once its repository is added.

1. Publish `build/kpm-repo/` (from `tools/package_kpm.sh`) somewhere public,
   for example GitHub Pages. Its `manifest.json` URL is the repository address.
2. Add the repository once. The Kindle search bar refuses `.` and `:`, so do
   this in a terminal: type `;kpm install kterm` in the search bar, open kterm, and run
   `kpm add-repo https://<your-site>/manifest.json` then `kpm update`.
3. From then on, type `;kpm install tome` in the search bar (and `;kpm upgrade` for updates).
4. Open **Tome** from your Kindle library. Settings, API keys and reading data
   live in `/mnt/us/tome/`, which upgrades and uninstalls leave alone.

Without a repository, copy the `.kpkg` to the Kindle and run
`kpm install file:///mnt/us/tome_0.2.0_kindlepw2-kindlehf.kpkg` in kterm.

## Install over USB (with KUAL)

1. Connect the Kindle over USB and unzip `tome-kindle.zip` at the root of the
   drive, so you get `/mnt/us/tome/` and `/mnt/us/extensions/tome/`.
2. Copy `tome/config.example.lua` to `tome/config.lua` and set up a provider.
   For Claude, put your API key in `tome/anthropic.key`.
3. Put EPUBs in `documents/`.
4. Eject, open KUAL → **Tome** → **Start Tome**. Wi-Fi must be on for recaps.

Leave a book with **Home** in the reader menu; exit with **Exit Tome** on the home screen.
Logs go to `/mnt/us/tome/crash.log`.

## First run on a device

Tome has been tested in the desktop emulator only. On first use on a Kindle, check:

- **Taps land in the wrong place**: set `kindle.touch_swap_xy` / `touch_mirror_x` / `touch_mirror_y` in `config.lua`.
- **Clock or status bar draws over pages**: start with **Start Tome (stop framework)**.
- **Page buttons reversed** (Voyage vs. Oasis): set `kindle.keymap = { [104] = "prev", [109] = "next" }`.
- **Recap fails with a TLS error**: old firmware curl may lack current CA certificates; set `ca_bundle`.
- `crash.log` lists the detected framebuffer size and input devices.

## Develop on a desktop

```bash
make -C native
```

```bash
python3 tools/make_test_epub.py tests/fixtures/gulls_reach.epub
```

```bash
luajit tests/run_tests.lua
```

Run with a window (SDL2; click = tap, right-click = long-press, drag = swipe, arrows/PgUp/PgDn, `m` = menu, `q` = quit):

```bash
luajit main.lua --sdl
```

Or headless with a script (see `tome/device/emulator.lua` for commands); screens go to `--out`:

```bash
luajit main.lua --script my_script.txt --out /tmp/tome_screens
```

`tests/mock_llm.py` is a fake Claude/OpenAI server for testing the recap plugin without an API key.

## About the recap's default model

The Claude provider defaults to `claude-opus-5-5` with effort `medium` for the
final recap and `low` for chapter notes, and sends `fallbacks: "default"`
(beta `server-side-fallback-2026-07-01`) so that a safety-classifier refusal is
retried on a fallback model. Set `fallbacks = false` on the provider to turn
that off, or pick a cheaper model with `model = "claude-haiku-5-5"`.

## License

Tome's code: MIT (see `LICENSE`). Bundled bitmap fonts are derived from
Caladea and Carlito (SIL Open Font License 1.1), Bitstream Charter (Bitstream
license; Charter is a trademark of Bitstream Inc.) and DejaVu Sans (Bitstream
Vera license); see `fonts/LICENSE-*.txt`.
