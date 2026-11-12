--[[
LLM providers for the recap plugin.

  type = "anthropic"  Claude Messages API (POST /v1/messages)
  type = "openai"     any OpenAI-compatible /chat/completions endpoint:
                      OpenAI, OpenRouter, Ollama (http://host:11434/v1),
                      LM Studio, llama.cpp server, ...

Every provider exposes: complete(system, user, opts) -> text | nil, err
`opts.effort` ("low"|"medium"|"high") and `opts.max_tokens` are hints.
Must be called from inside an app task (HTTP yields).
--]]
local plugin = ...
local app = plugin.app
local UI = require("tome.ui.manager")
local util = require("tome.util")
local log = require("tome.log")

local Providers = {}

local ANTHROPIC_VERSION = "2026-10-21"

local function sleep_in_task(ms)
    local deadline = app.device:monotonic_ms() + ms
    return UI.await(function() return app.device:monotonic_ms() >= deadline end)
end

--- Pull the key out of whatever the key file contains. Editors add extras:
-- a UTF-8 byte-order mark (Windows Notepad), rich-text markup (Mac TextEdit),
-- quotes, "KEY=..." prefixes, line breaks. Any of those inside an HTTP header
-- makes the server reject the request outright.
local KEY_PATTERNS = {
    "sk%-ant%-[%w_%-]+",   -- Anthropic
    "AIza[%w_%-]+",        -- Google Gemini
    "gsk_[%w]+",           -- Groq
    "sk%-or%-[%w_%-]+",    -- OpenRouter
    "sk%-[%w_%-]+",        -- OpenAI and similar
}

local function clean_key(raw)
    if not raw then return nil end
    local s = raw:gsub("^\239\187\191", "") -- byte-order mark
    for _, pat in ipairs(KEY_PATTERNS) do
        local k = s:match(pat)
        if k and #k >= 20 then return k end
    end
    -- unknown format: the longest run of key-like characters
    local best = ""
    for tok in s:gmatch("[%w_%-%.]+") do
        if #tok > #best then best = tok end
    end
    if #best >= 16 then return best end
    return util.trim(s) ~= "" and util.trim(s) or nil
end
Providers.clean_key = clean_key

local function api_key(cfg)
    if cfg.api_key and cfg.api_key ~= "" then return clean_key(cfg.api_key) end
    if cfg.api_key_file then
        local raw = util.read_file(cfg.api_key_file)
        local k = clean_key(raw)
        if raw and k and util.trim(raw) ~= k then
            log.warn("recap: " .. cfg.api_key_file .. " contains more than the key; using just the key")
        end
        return k
    end
end

--- POST with retries on 429 / 5xx / 529 (overloaded).
local function post(req, attempts)
    attempts = attempts or 3
    local res, err
    for i = 1, attempts do
        res, err = app.http:request(req)
        if not res then
            if err == "cancelled" then return nil, err end
        elseif res.status == 429 or res.status >= 500 then
            err = string.format("HTTP %d", res.status)
            local msg = res.json and res.json.error and res.json.error.message
            if msg then err = err .. ": " .. msg end
        else
            return res
        end
        if i < attempts then
            log.warn("recap: request failed (" .. tostring(err) .. "), retrying")
            if not sleep_in_task(2000 * i) then return nil, "cancelled" end
        end
    end
    return nil, err
end

--- Human-readable message from an error response (OpenAI style, or
-- Gemini's which wraps it in a list: [{"error": {...}}]).
local function error_message(res)
    local body = res.body or ""
    if body:match("^%s*<") then
        -- An HTML page instead of an API reply: the request was rejected before
        -- reaching the API (typically a malformed header, e.g. a bad key file).
        local title = body:match("<title>(.-)</title>") or "HTML error page"
        return title:gsub("!+%d*$", "") .. " - the server rejected the request itself. "
            .. "Check that the key file contains only the API key, saved as plain text."
    end
    local j = res.json
    local e = j and (j.error or (j[1] and j[1].error))
    if type(e) == "table" then return e.message or e.status or app.json.encode(e) end
    if type(e) == "string" then return e end
    return (res.body or ""):gsub("%s+", " "):sub(1, 300)
end

local function anthropic(cfg)
    local base = (cfg.base_url or "https://api.anthropic.com"):gsub("/$", "")
    local model = cfg.model or "claude-opus-5-5"
    local p = { name = cfg.label or ("Claude (" .. model .. ")"), model = model }
    function p.complete(system, user, opts)
        opts = opts or {}
        local key = api_key(cfg)
        if not key then return nil, "No API key configured for the Anthropic provider." end
        local body = {
            model = model,
            max_tokens = opts.max_tokens or 16000,
            system = system,
            messages = { { role = "user", content = user } },
            output_config = { effort = opts.effort or cfg.effort or "medium" },
        }
        local headers = {
            ["x-api-key"] = key,
            ["anthropic-version"] = ANTHROPIC_VERSION,
        }
        -- If a safety classifier declines, let the API retry on a fallback model.
        if cfg.fallbacks ~= false then
            body.fallbacks = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        end
        local res, err = post({ url = base .. "/v1/messages", headers = headers, body = body,
            timeout = cfg.timeout or 300 })
        if not res then return nil, err end
        local j = res.json
        if res.status ~= 200 or not j then
            local msg = error_message(res)
            log.error(string.format("recap: Claude API returned HTTP %d: %s", res.status, msg))
            return nil, string.format("Claude API error %d: %s", res.status, msg)
        end
        if j.stop_reason == "refusal" then
            return nil, "The model declined to summarize this text."
        end
        local parts = {}
        for _, block in ipairs(j.content or {}) do
            if block.type == "text" then parts[#parts + 1] = block.text end
        end
        if #parts == 0 then return nil, "Empty response from Claude" end
        local text = table.concat(parts)
        if j.stop_reason == "max_tokens" then text = text .. "\n\n(Recap was cut off.)" end
        return text, { input_tokens = j.usage and j.usage.input_tokens, output_tokens = j.usage and j.usage.output_tokens }
    end
    return p
end

--- Version-ish sort key for model ids like "gemini-2.5-flash-001".
local function model_rank(id)
    local major, minor = id:match("(%d+)%.(%d+)")
    local v = (tonumber(major) or tonumber(id:match("%-(%d+)%-")) or 0) * 100 + (tonumber(minor) or 0)
    -- previews/experiments can vanish without notice: only if nothing stable exists
    if id:find("preview") or id:find("exp") then v = v - 100000 end
    return v
end

local function openai(cfg)
    local base = (cfg.base_url or "https://api.openai.com/v1"):gsub("/$", "")
    local p = { name = cfg.label or (base:match("//([^/]+)") or base), model = cfg.model }

    local function headers()
        local h = {}
        local key = api_key(cfg)
        if key then h["authorization"] = "Bearer " .. key end
        for k, v in pairs(cfg.headers or {}) do h[k] = v end
        return h
    end

    --- model = "auto": ask the service which models this key can use and
    -- pick the newest general "flash"-class model (or `prefer` from config).
    local function auto_model(refresh)
        local cache_key = "auto_model:" .. base
        if not refresh then
            local cached = plugin.settings:get(cache_key)
            if cached then return cached end
        end
        local res, err = app.http:request({ url = base .. "/models", method = "GET", headers = headers(), timeout = 60 })
        if not res then return nil, err end
        if res.status ~= 200 then
            return nil, string.format("Could not list models (HTTP %d): %s", res.status, error_message(res))
        end
        local want = cfg.prefer or "flash"
        local best, best_rank
        for _, m in ipairs((res.json and res.json.data) or {}) do
            local id = tostring(m.id or ""):gsub("^models/", "")
            local skip = id:find("image") or id:find("tts") or id:find("audio") or id:find("live")
                or id:find("embed") or id:find("vision") or id:find("lite") or id:find("8b")
            if not skip and id:find(want, 1, true) then
                local r = model_rank(id)
                if not best_rank or r > best_rank then best, best_rank = id, r end
            end
        end
        if not best then return nil, "No '" .. want .. "' model is available for this key" end
        log.info("recap: auto-selected model", best)
        plugin.settings:set(cache_key, best)
        plugin.settings:save()
        return best
    end

    function p.complete(system, user, opts)
        opts = opts or {}
        local model = cfg.model
        local auto = model == nil or model == "auto"
        if auto then
            local err
            model, err = auto_model(false)
            if not model then return nil, err end
        end
        p.model = model
        local body = {
            model = model,
            messages = { { role = "system", content = system }, { role = "user", content = user } },
        }
        if cfg.max_tokens_field ~= false then body[cfg.max_tokens_field or "max_tokens"] = opts.max_tokens or 4000 end
        local res, err = post({ url = base .. "/chat/completions", headers = headers(), body = body,
            timeout = cfg.timeout or 600 })
        if not res then return nil, err end
        local j = res.json
        if (res.status == 400 or res.status == 404) and auto and error_message(res):lower():find("model") then
            -- the remembered model was retired: pick again once
            model = auto_model(true)
            if model and model ~= body.model then
                body.model, p.model = model, model
                res, err = post({ url = base .. "/chat/completions", headers = headers(), body = body,
                    timeout = cfg.timeout or 600 })
                if not res then return nil, err end
                j = res.json
            end
        end
        if res.status ~= 200 or not j then
            local msg = error_message(res)
            log.error(string.format("recap: %s returned HTTP %d for model %s: %s", p.name, res.status, tostring(body.model), msg))
            return nil, string.format("API error %d (model %s): %s", res.status, tostring(body.model), msg)
        end
        local choice = j.choices and j.choices[1]
        local text = choice and choice.message and choice.message.content
        if type(text) ~= "string" or text == "" then return nil, "Empty response from " .. p.name end
        -- Some local reasoning models inline their thinking; drop it.
        text = text:gsub("^%s*<think>.-</think>%s*", "")
        return text, j.usage
    end
    return p
end

local BUILDERS = { anthropic = anthropic, openai = openai, ollama = openai }

--- Build the provider named `name` from the plugin config.
function Providers.get(name)
    local all = plugin.settings:get("providers", {})
    local cfg = all[name]
    if not cfg then return nil, "Unknown provider '" .. tostring(name) .. "'. Check config.lua." end
    local builder = BUILDERS[cfg.type or name]
    if not builder then return nil, "Unknown provider type '" .. tostring(cfg.type) .. "'" end
    return builder(cfg)
end

function Providers.names()
    local out = {}
    for k in pairs(plugin.settings:get("providers", {})) do out[#out + 1] = k end
    table.sort(out)
    return out
end

return Providers
