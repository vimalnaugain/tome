-- Tome configuration. Copy to config.lua (next to main.lua) and edit.
-- On the Kindle that is /mnt/us/tome/config.lua (edit over USB).
-- This file is plain data: no function calls or os.* here.
return {
    -- Where your EPUBs live and where Tome keeps its state.
    -- books_dir = "/mnt/us/documents",
    -- data_dir = "/mnt/us/tome/data",

    -- Sleep: Tome keeps the Kindle awake while it runs and puts it to sleep
    -- itself after this many idle minutes (0 = never). The power button works as usual.
    -- sleep_after_minutes = 10,

    -- log_level = "info",            -- "debug" for troubleshooting
    -- log_file = "/mnt/us/tome/tome.log",

    -- HTTPS goes through the Kindle's own curl. If TLS fails on old firmware,
    -- point this at a current CA bundle (e.g. a copy of curl's cacert.pem).
    -- ca_bundle = "/mnt/us/tome/cacert.pem",

    kindle = {
        -- flash_every = 6,            -- full e-ink refresh every N page turns (0 = never)
        -- Touch calibration, only if taps land in the wrong place:
        -- touch_swap_xy = false, touch_mirror_x = false, touch_mirror_y = false,
        -- Page-turn buttons (Oasis/Voyage). Key codes -> "next" | "prev" | "menu" | "back"
        -- keymap = { [104] = "next", [109] = "prev" },
        -- screen_width = 1072, screen_height = 1448, dpi = 300,
    },

    settings = {
        reader = { font_size = 34, line_spacing = 1.3, justify = true },
        -- resume_last = true,         -- reopen the last book on start
        -- sleep_screen = "cover",     -- "cover" (whole cover), "cover_fill" (fills the screen), "off"
    },

    plugins = {
        recap = {
            -- Which entry of `providers` to use.
            provider = "claude",
            providers = {
                claude = {
                    type = "anthropic",
                    -- Put the key here, or in a file and use api_key_file.
                    api_key_file = "/mnt/us/tome/anthropic.key",
                    -- api_key = "sk-ant-...",
                    model = "claude-opus-5-5",
                    -- effort = "medium",
                },
                -- Any OpenAI-compatible endpoint:
                -- openai = { type = "openai", base_url = "https://api.openai.com/v1",
                --            api_key_file = "/mnt/us/tome/openai.key", model = "your-model" },
                -- A model on your own computer via Ollama (same Wi-Fi network):
                -- ollama = { type = "openai", base_url = "http://192.168.1.20:11434/v1", model = "llama3.1" },
            },
            length = "medium",              -- "short" | "medium" | "long"
            auto_offer_after_days = 3,      -- offer a recap when reopening a book after N days (0 = off)
            single_pass_chars = 200000,     -- up to this much text read: one request with all of it
            recent_chars = 12000,           -- verbatim recent text added to a full recap
            quick_recent_chars = 15000,     -- text used by "Quick recap"
            confirm_after_chapters = 6,     -- ask before summarizing this many chapters at once
        },
    },
}
