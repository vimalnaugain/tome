# Story recap for KOReader

A KOReader port of Tome's recap plugin: a spoiler-free "previously on…" of
the book you're reading, written by an LLM from the pages you've already read.
It can use Claude, any OpenAI-compatible API, or Ollama on your network.

## Install

1. Get `recap.koplugin.zip`. It's published next to the KPM repository on
   GitHub Pages (`https://<user>.github.io/tome/recap.koplugin.zip`), or you
   can build it with `tools/package_koreader.sh`.
2. Connect the Kindle (or any KOReader device) over USB and unzip it into
   KOReader's `plugins/` folder. On a Kindle that is
   `/mnt/us/koreader/plugins/`, which gives you `/mnt/us/koreader/plugins/recap.koplugin/`.
3. Restart KOReader.
4. Open a book, then go to **Tools (🛠) → Recap → Settings → API key** and enter your key.

## Use

Open the top menu, then go to **Tools → Recap**:

- **Quick recap**: what's happening in the last few pages, plus anything
  already noted from earlier chapters.
- **Story so far**: everything up to this page. Short books (up to about
  200,000 characters read) go in one request. For longer books, each finished
  chapter is summarized once and the notes are saved in the book's `.sdr`
  folder, so later recaps are quick. If many chapters still need notes, you're
  asked before it starts.
- **Show last recap**: shows the previous recap again without going online.

While a recap is being written, tap the screen to cancel.

When you come back to a book after a few days (3 by default), KOReader offers
a quick recap. You can change or turn this off under **Settings → Offer a
recap when I come back**.

You can also put **Recap: quick**, **Recap: story so far** and **Recap: show
last** on a gesture under **Settings → Taps and gestures → Gesture manager**.

## Settings

Everything is under **Tools → Recap → Settings**:

| Setting | |
|---|---|
| Service | Claude (Anthropic), an OpenAI-compatible API, or Ollama |
| API key | Saved on the device in `koreader/settings/recap.lua`. Long-press to remove it |
| Model | Default `claude-opus-5-5` for Claude, `llama3.1` for Ollama |
| Server | Leave empty for the default. For Ollama or LM Studio, use your computer's address, e.g. `http://192.168.1.20:11434/v1` |
| Recap length | Short (~120 words), Medium (~300), Long (~600) |

For advanced options, edit `koreader/settings/recap.lua` while KOReader is
closed: `effort`, `single_pass_chars`, `recent_chars`, `quick_recent_chars`,
`chunk_chars`, `confirm_after_chapters`. In each provider entry you can also
set `api_key_file` (a path to a file holding the key), `headers`, and
`timeout`.

## Spoilers

Only text up to the end of the last word on screen is ever sent to the
model. For EPUB, FB2, MOBI and other reflowable books, this is the exact
crengine position. For PDF and DjVu, it's the end of the current page.
Chapters come from the table of contents. Books without a table of contents
are split into parts of about 60,000 characters. The prompt also tells the
model not to use anything it already knows about the book.

## Development

```bash
sudo apt-get install luajit lua-cjson
```

```bash
luajit koreader/tests/run_tests.lua
```

The tests replace KOReader's modules with small fakes, and a fake crengine
reader serves a generated book, so spoiler boundaries, caching, providers,
menus and the "welcome back" offer are all checked without a device.

Files:

- `main.lua`: menu, settings, gesture actions, the "welcome back" offer, and
  running requests in a subprocess the user can cancel (`Trapper`)
- `recap_book.lua`: gets the text read so far and the finished chapters from
  KOReader (crengine XPointers, or PDF/DjVu page text)
- `recap_engine.lua`: the recap strategy and prompts. No KOReader
  dependencies, shared logic with Tome's `plugins/recap.plugin/recap.lua`
- `recap_providers.lua`: Claude Messages API and OpenAI-compatible
  `/chat/completions` over KOReader's LuaSocket
