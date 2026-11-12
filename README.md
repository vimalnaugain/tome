# Tome

A small EPUB reader for jailbroken Kindles, built to host plugins. Its first
plugin is **Story recap**: a spoiler-free "previously on…" of the book you are
reading, written by an LLM (Claude, any OpenAI-compatible API, or a local
Ollama) from the pages you have already read.

Tome borrows ideas, not code, from [KOReader](https://github.com/koreader/koreader):
how to take over the Kindle screen and input, and the folder-per-plugin layout.
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Features

- EPUB 2/3 (DRM-free): table of contents, italics/bold, headings, quotes, lists
- Justified text, 7 font sizes, line spacing, go to %, position saved per book
- Tap right/left (or swipe, or page buttons) to turn pages, tap the top for the menu
- Plugin API with menus, page events, background HTTP tasks ([docs/PLUGIN_API.md](docs/PLUGIN_API.md))
- Recap plugin:
  - **Quick recap**: the last ~15k characters you read, plus cached chapter notes
  - **Story so far**: the whole book so far; long books are summarized chapter by chapter once and cached
  - Offers a recap when you reopen a book after a few days
  - Never sends text past the end of the current page

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

## Install

1. Connect the Kindle over USB and unzip `tome-kindle.zip` at the root of the
   drive, so you get `/mnt/us/tome/` and `/mnt/us/extensions/tome/`.
2. Copy `tome/config.example.lua` to `tome/config.lua` and set up a provider.
   For Claude, put your API key in `tome/anthropic.key`.
3. Put EPUBs in `documents/`.
4. Eject, open KUAL → **Tome** → **Start Tome**. Wi-Fi must be on for recaps.

Exit with the ✕ on the library screen (or **Exit Tome** in the reader menu).
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
Caladea and Carlito (SIL Open Font License 1.1) and DejaVu Sans (Bitstream
Vera license); see `fonts/LICENSE-*.txt`.
