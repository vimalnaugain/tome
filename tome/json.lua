--[[
Small JSON encoder/decoder. Arrays are Lua sequences; use json.null for null
and json.empty_array to force "[]".
--]]
local json = {}

json.null = setmetatable({}, { __tostring = function() return "null" end })
json.empty_array = setmetatable({}, { __tostring = function() return "[]" end })

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
    ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode_string(s)
    return '"' .. s:gsub('[%c"\\]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k <= 0 or k % 1 ~= 0 then return false end
        n = n + 1
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end

local function encode(v, buf)
    local tv = type(v)
    if v == nil or v == json.null then
        buf[#buf + 1] = "null"
    elseif v == json.empty_array then
        buf[#buf + 1] = "[]"
    elseif tv == "boolean" then
        buf[#buf + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then error("json: cannot encode " .. tostring(v)) end
        if v % 1 == 0 and v > -1e15 and v < 1e15 then
            buf[#buf + 1] = string.format("%d", v)
        else
            buf[#buf + 1] = string.format("%.14g", v)
        end
    elseif tv == "string" then
        buf[#buf + 1] = encode_string(v)
    elseif tv == "table" then
        local arr, n = is_array(v)
        if arr and n > 0 then
            buf[#buf + 1] = "["
            for i = 1, n do
                if i > 1 then buf[#buf + 1] = "," end
                encode(v[i], buf)
            end
            buf[#buf + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do
                if type(k) ~= "string" then error("json: object keys must be strings") end
                keys[#keys + 1] = k
            end
            table.sort(keys)
            buf[#buf + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then buf[#buf + 1] = "," end
                buf[#buf + 1] = encode_string(k)
                buf[#buf + 1] = ":"
                encode(v[k], buf)
            end
            buf[#buf + 1] = "}"
        end
    else
        error("json: cannot encode type " .. tv)
    end
end

function json.encode(v)
    local buf = {}
    encode(v, buf)
    return table.concat(buf)
end

local function utf8_char(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    if cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
    end
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end
json.utf8_char = utf8_char

function json.decode(s)
    local pos = 1
    local function err(msg) error(string.format("json: %s at position %d", msg, pos), 0) end
    local function ws() pos = s:find("[^ \t\r\n]", pos) or #s + 1 end
    local value

    local function str()
        pos = pos + 1
        local parts = {}
        while true do
            local a, b = s:find('["\\]', pos)
            if not a then err("unterminated string") end
            parts[#parts + 1] = s:sub(pos, a - 1)
            if s:sub(a, a) == '"' then pos = a + 1; break end
            local c = s:sub(a + 1, a + 1)
            if c == "u" then
                local cp = tonumber(s:sub(a + 2, a + 5), 16) or err("bad unicode escape")
                pos = a + 6
                if cp >= 0xD800 and cp <= 0xDBFF and s:sub(pos, pos + 1) == "\\u" then
                    local lo = tonumber(s:sub(pos + 2, pos + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                        pos = pos + 6
                    end
                end
                parts[#parts + 1] = utf8_char(cp)
            else
                local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                parts[#parts + 1] = map[c] or c
                pos = a + 2
            end
        end
        return table.concat(parts)
    end

    function value()
        ws()
        local c = s:sub(pos, pos)
        if c == "{" then
            pos = pos + 1
            local obj = {}
            ws()
            if s:sub(pos, pos) == "}" then pos = pos + 1; return obj end
            while true do
                ws()
                if s:sub(pos, pos) ~= '"' then err("expected key") end
                local k = str()
                ws()
                if s:sub(pos, pos) ~= ":" then err("expected ':'") end
                pos = pos + 1
                obj[k] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "}" then return obj end
                if d ~= "," then err("expected ',' or '}'") end
            end
        elseif c == "[" then
            pos = pos + 1
            local arr = {}
            ws()
            if s:sub(pos, pos) == "]" then pos = pos + 1; return arr end
            while true do
                arr[#arr + 1] = value()
                ws()
                local d = s:sub(pos, pos)
                pos = pos + 1
                if d == "]" then return arr end
                if d ~= "," then err("expected ',' or ']'") end
            end
        elseif c == '"' then
            return str()
        elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
        elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
        elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return json.null
        else
            local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
            if not num or num == "" then err("unexpected character '" .. c .. "'") end
            pos = pos + #num
            return tonumber(num)
        end
    end

    local ok, res = pcall(function()
        local v = value()
        ws()
        if pos <= #s then err("trailing data") end
        return v
    end)
    if not ok then return nil, res end
    return res
end

return json
