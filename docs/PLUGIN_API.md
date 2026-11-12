# Tome plugin API (version 1)

A plugin is a folder in `plugins/` named `<name>.plugin`:

```
plugins/hello.plugin/_meta.lua
plugins/hello.plugin/main.lua
```

`_meta.lua`:

```lua
return { name = "hello", fullname = "Hello", description = "…", version = "0.1", api = 1 }
```

`main.lua` returns a table of methods. Tome creates one instance per plugin
and sets these fields before calling `init`:

| Field | |
|---|---|
| `self.app` | the application (below) |
| `self.name`, `self.dir`, `self.meta` | identity |
| `self.settings` | `:get(key, default)`, `:set(key, v)`, `:save()`, `:data_dir()`; defaults come from `config.lua` → `plugins.<name>` |
| `self:require("mod")` | load `mod.lua` from the plugin folder; the chunk receives the plugin as `...` |

```lua
local Hello = {}

function Hello:init() end

function Hello:addToReaderMenu(items, reader)
    items[#items + 1] = { text = "Say hello", callback = function()
        self.app:notify("You are on page " .. reader:position().page)
    end }
end

function Hello:onPageChanged(reader, pos) end

return Hello
```

Errors in any plugin method are caught and logged; they never crash Tome.

## Hooks

| Method | When |
|---|---|
| `init()` | after loading |
| `onAppStart(app)` | library shown |
| `onReaderReady(reader)` | a book was opened |
| `onPageChanged(reader, pos)` | after every page turn / jump |
| `onReaderHold(reader, ev)` | long-press on the page (`ev.x`, `ev.y`) |
| `onReaderClose(reader)` | before the book closes |
| `onExit(app)` | Tome is quitting |
| `addToReaderMenu(items, reader)` | reader menu is opening; append/insert items |
| `addToMainMenu(items)` | library menu (Menu key) is opening |

Menu items: `{ text = string|fn, callback = fn, submenu = items|fn, checked = bool|fn, enabled = bool|fn, keep_open = bool }`.

## `reader`

| Method | Returns |
|---|---|
| `book_info()` | `{ id, title, authors, language, path, chapters }` (`id` is stable across renames) |
| `position()` | first char on screen: `{ chapter, block, offset, percent, chapter_title, page, pages, chapter_seconds_left, book_seconds_left }` |
| `time_left()` | seconds left in the chapter and in the book, at the reader's learned pace |
| `page_end()` | position just past the last char on screen |
| `chapters()` | `{ {index, title}, … }` |
| `text_range(from, to)` | plain text, paragraphs separated by blank lines, headings as `## …`; `nil` bounds = start/end of book |
| `chapter_text(i, upto)` | chapter `i`, optionally cut at position `upto` |
| `text_read_so_far(max_chars)` | text up to `page_end()`, last `max_chars` characters, starting at a paragraph |
| `last_read_time()` | `os.time()` of the previous session, or `nil` |
| `go_to(pos)` | jump |

## `app`

| | |
|---|---|
| `app:notify(text, ms)` | toast |
| `app:show_text{title, text}` | full-screen paginated text (`#`/`##` headings, `- ` bullets, `**bold**`) |
| `app:show_progress{title, text, on_cancel}` | returns `{ set_text, close }` |
| `app:confirm{title, text, ok_text, cancel_text, on_ok, on_cancel}` | |
| `app:choose{title, items = {{text, value}}, on_choose}` | list picker |
| `app:run_task(fn, on_error)` | run `fn` as a coroutine; returns `{ cancel }` |
| `app.http:request{url, method, headers, body, timeout}` | `{status, body, json}` or `nil, err`. Inside a task it yields (UI stays responsive); `body` may be a table (sent as JSON) |
| `app.json`, `app.util`, `app.log` | helpers |
| `app.device` | `width`, `height` (logical, after rotation), `dpi`, `rotation`, `is_kindle`, `battery()`, `wifi_enable()` |
| `app.stats` | reading statistics: `chars_per_minute()`, `year()`, `week_seconds()`, `streak_days()`, `is_finished(id)` |
| `app.ui:schedule(ms, fn)` | timer |
| `require("tome.ui.manager").await(pred)` | inside a task: wait until `pred()` is true; returns `false` if cancelled |
