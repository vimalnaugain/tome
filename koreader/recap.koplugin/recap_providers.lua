--[[--
LLM providers for the recap plugin.

  type = "anthropic"  Claude Messages API (POST /v1/messages)
  type = "openai"     any OpenAI-compatible /chat/completions endpoint:
                      OpenAI, OpenRouter, Ollama (http://host:11434/v1),
                      LM Studio, llama.cpp server, ...

Every provider exposes: complete(system, user, opts) -> text | nil, err
`opts.effort` ("low"|"medium"|"high") and `opts.max_tokens` are hints.

complete() blocks; the plugin runs it in a subprocess (Trapper) so the
reader stays responsive and the user can cancel.
--]]
local Providers = {}

Providers.ANTHROPIC_VERSION = "2026-10-21"
Providers.DEFAULT_CLAUDE_MODEL = "claude-opus-5-5"

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end

-- JSON: KOReader ships "json" (luajson); tests may inject another codec.
Providers.json = nil
local function json()
    if not Providers.json then
        local JSON = require("json")
        Providers.json = {
            encode = JSON.encode,
            decode = function(s) return JSON.decode(s, JSON.decode.simple) end,
        }
    end
    return Providers.json
end

--- Blocking HTTPS POST. Returns status, body | nil, err. Replaceable for tests.
function Providers.http_post(url, headers, body, timeout)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink = {}
    -- The model can take a while before the first byte: generous block timeout.
    socketutil:set_timeout(timeout or 300, (timeout or 300) * 2)
    local hdrs = { ["content-type"] = "application/json", ["content-length"] = tostring(#body) }
    for k, v in pairs(headers) do hdrs[k] = v end
    local code, resp_headers, status = socket.skip(1, http.request{
        url = url,
        method = "POST",
        headers = hdrs,
        source = ltn12.source.string(body),
        sink = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if resp_headers == nil then
        return nil, "Network error: " .. tostring(status or code)
    end
    return tonumber(code), table.concat(sink)
end

function Providers.sleep(seconds)
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil.sleep then ffiutil.sleep(seconds) else os.execute("sleep " .. tonumber(seconds)) end
end

local function api_key(cfg)
    if cfg.api_key and cfg.api_key ~= "" then return trim(cfg.api_key) end
    if cfg.api_key_file and cfg.api_key_file ~= "" then
        local k = read_file(cfg.api_key_file)
        if k and trim(k) ~= "" then return trim(k) end
    end
end

--- POST JSON with retries on network errors, 429, 5xx and 529 (overloaded).
local function post(url, headers, body, timeout, attempts)
    attempts = attempts or 3
    local payload = json().encode(body)
    local err
    for i = 1, attempts do
        local status, resp = Providers.http_post(url, headers, payload, timeout)
        local j
        if status then
            local ok, decoded = pcall(json().decode, resp)
            if ok and type(decoded) == "table" then j = decoded end
        end
        if status and status ~= 429 and status < 500 then
            return { status = status, body = resp or "", json = j }
        end
        if status then
            err = string.format("HTTP %d", status)
            local msg = j and type(j.error) == "table" and j.error.message
            if msg then err = err .. ": " .. msg end
        else
            err = resp
        end
        if i < attempts then Providers.sleep(2 * i) end
    end
    return nil, err
end

local function error_message(res, prefix)
    local j = res.json
    local msg = j and j.error and (type(j.error) == "table" and j.error.message or tostring(j.error))
    return string.format("%s %d: %s", prefix, res.status, msg or res.body:sub(1, 200))
end

local function anthropic(cfg)
    local base = (cfg.base_url and cfg.base_url ~= "" and cfg.base_url or "https://api.anthropic.com"):gsub("/+$", "")
    local model = cfg.model and cfg.model ~= "" and cfg.model or Providers.DEFAULT_CLAUDE_MODEL
    local p = { name = cfg.label or ("Claude (" .. model .. ")"), model = model }
    function p.complete(system, user, opts)
        opts = opts or {}
        local key = api_key(cfg)
        if not key then return nil, "No API key set for Claude. Add one in Recap → Settings." end
        local body = {
            model = model,
            max_tokens = opts.max_tokens or 16000,
            system = system,
            messages = { { role = "user", content = user } },
            output_config = { effort = opts.effort or cfg.effort or "medium" },
        }
        local headers = {
            ["x-api-key"] = key,
            ["anthropic-version"] = Providers.ANTHROPIC_VERSION,
        }
        -- If a safety classifier declines, let the API retry on a fallback model.
        if cfg.fallbacks ~= false then
            body.fallbacks = "default"
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        end
        local res, err = post(base .. "/v1/messages", headers, body, cfg.timeout or 300)
        if not res then return nil, err end
        local j = res.json
        if res.status ~= 200 or not j then return nil, error_message(res, "Claude API error") end
        if j.stop_reason == "refusal" then
            return nil, "The model declined to summarize this text."
        end
        local parts = {}
        for _, block in ipairs(j.content or {}) do
            if block.type == "text" and type(block.text) == "string" then parts[#parts + 1] = block.text end
        end
        if #parts == 0 then return nil, "Empty response from Claude" end
        local text = table.concat(parts)
        if j.stop_reason == "max_tokens" then text = text .. "\n\n(Recap was cut off.)" end
        return text
    end
    return p
end

local function openai(cfg)
    local default_base = cfg.type == "ollama" and "http://localhost:11434/v1" or "https://api.openai.com/v1"
    local base = (cfg.base_url and cfg.base_url ~= "" and cfg.base_url or default_base):gsub("/+$", "")
    local model = cfg.model ~= "" and cfg.model or nil
    local p = { name = cfg.label or ((model or "?") .. " @ " .. (base:match("//([^/]+)") or base)), model = model }
    function p.complete(system, user, opts)
        opts = opts or {}
        if not model then return nil, "No model set for " .. p.name .. ". Add one in Recap → Settings." end
        local headers = {}
        local key = api_key(cfg)
        if key then headers["authorization"] = "Bearer " .. key end
        for k, v in pairs(cfg.headers or {}) do headers[k] = v end
        local body = {
            model = model,
            messages = { { role = "system", content = system }, { role = "user", content = user } },
        }
        if cfg.max_tokens_field ~= false then body[cfg.max_tokens_field or "max_tokens"] = opts.max_tokens or 4000 end
        local res, err = post(base .. "/chat/completions", headers, body, cfg.timeout or 600)
        if not res then return nil, err end
        local j = res.json
        if res.status ~= 200 or not j then return nil, error_message(res, "API error") end
        local choice = j.choices and j.choices[1]
        local text = choice and choice.message and choice.message.content
        if type(text) ~= "string" or text == "" then return nil, "Empty response from " .. p.name end
        -- Some local reasoning models inline their thinking; drop it.
        text = text:gsub("^%s*<think>.-</think>%s*", "")
        return text
    end
    return p
end

local BUILDERS = { anthropic = anthropic, openai = openai, ollama = openai }

Providers.TYPES = {
    { id = "anthropic", text = "Claude (Anthropic)" },
    { id = "openai", text = "OpenAI-compatible API" },
    { id = "ollama", text = "Ollama on my network" },
}

--- Build a provider from its config table.
function Providers.build(cfg)
    if type(cfg) ~= "table" then return nil, "No recap provider configured. Open Recap → Settings." end
    local builder = BUILDERS[cfg.type or "anthropic"]
    if not builder then return nil, "Unknown provider type '" .. tostring(cfg.type) .. "'" end
    return builder(cfg)
end

return Providers
