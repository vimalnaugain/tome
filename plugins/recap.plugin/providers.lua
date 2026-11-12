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

local function api_key(cfg)
    if cfg.api_key and cfg.api_key ~= "" then return cfg.api_key end
    if cfg.api_key_file then
        local k = util.read_file(cfg.api_key_file)
        if k then return util.trim(k) end
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
            local msg = j and j.error and j.error.message or res.body:sub(1, 200)
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

local function openai(cfg)
    local base = (cfg.base_url or "https://api.openai.com/v1"):gsub("/$", "")
    local model = cfg.model
    local p = { name = cfg.label or (model or "?") .. " @ " .. (base:match("//([^/]+)") or base), model = model }
    function p.complete(system, user, opts)
        opts = opts or {}
        if not model then return nil, "No model configured for provider " .. p.name end
        local headers = {}
        local key = api_key(cfg)
        if key then headers["authorization"] = "Bearer " .. key end
        for k, v in pairs(cfg.headers or {}) do headers[k] = v end
        local body = {
            model = model,
            messages = { { role = "system", content = system }, { role = "user", content = user } },
        }
        if cfg.max_tokens_field ~= false then body[cfg.max_tokens_field or "max_tokens"] = opts.max_tokens or 4000 end
        local res, err = post({ url = base .. "/chat/completions", headers = headers, body = body,
            timeout = cfg.timeout or 600 })
        if not res then return nil, err end
        local j = res.json
        if res.status ~= 200 or not j then
            local msg = j and j.error and (j.error.message or tostring(j.error)) or res.body:sub(1, 200)
            return nil, string.format("API error %d: %s", res.status, tostring(msg))
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
