local bit = require("bit")

local util = {}

function util.shell_quote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

function util.mkdir_p(path)
    os.execute("mkdir -p " .. util.shell_quote(path))
end

function util.file_exists(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end

function util.read_file(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local s = f:read("*a")
    f:close()
    return s
end

--- Write atomically (temp file + rename) so a crash never leaves half a file.
function util.write_file(path, data)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return nil, err end
    f:write(data)
    f:close()
    local ok, rerr = os.rename(tmp, path)
    if not ok then return nil, rerr end
    return true
end

function util.dirname(path) return path:match("^(.*)/[^/]*$") or "." end
function util.basename(path) return path:match("([^/]+)$") or path end

--- List directory entries via `ls` (no lfs in the static binary).
-- Returns { {name=, is_dir=}, ... } sorted, dirs first.
function util.list_dir(path)
    local p = io.popen("ls -1Ap " .. util.shell_quote(path) .. " 2>/dev/null")
    local items = {}
    if p then
        for line in p:lines() do
            if line ~= "" then
                local is_dir = line:sub(-1) == "/"
                items[#items + 1] = { name = is_dir and line:sub(1, -2) or line, is_dir = is_dir }
            end
        end
        p:close()
    end
    table.sort(items, function(a, b)
        if a.is_dir ~= b.is_dir then return a.is_dir end
        return a.name:lower() < b.name:lower()
    end)
    return items
end

--- FNV-1a 32-bit hash, hex string.
function util.hash(s)
    local h = 0x811c9dc5
    for i = 1, #s do
        h = bit.bxor(h, s:byte(i))
        h = bit.tobit(h * 0x01000193 % 0x100000000)
    end
    return bit.tohex(h)
end

--- Stable book id: hash of size + first/last 64 KiB (survives renames).
function util.file_fingerprint(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    f:seek("set", 0)
    local head = f:read(65536) or ""
    f:seek("set", math.max(0, size - 65536))
    local tail = f:read(65536) or ""
    f:close()
    return util.hash(tostring(size) .. head) .. util.hash(tail .. tostring(size))
end

function util.trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

--- Iterate UTF-8 code points: for pos, cp, char in util.utf8_iter(s)
function util.utf8_iter(s)
    local i = 1
    local n = #s
    return function()
        if i > n then return nil end
        local c = s:byte(i)
        local len, cp
        if c < 0x80 then len, cp = 1, c
        elseif c < 0xE0 then len, cp = 2, bit.band(c, 0x1F)
        elseif c < 0xF0 then len, cp = 3, bit.band(c, 0x0F)
        else len, cp = 4, bit.band(c, 0x07) end
        for k = 1, len - 1 do
            local cc = s:byte(i + k)
            if not cc or bit.band(cc, 0xC0) ~= 0x80 then len = k; cp = 0xFFFD; break end
            cp = cp * 64 + bit.band(cc, 0x3F)
        end
        local start = i
        i = i + len
        return start, cp, s:sub(start, i - 1)
    end
end

--- Serialize a Lua value as a loadable chunk ("return {...}").
local function ser(v, indent, out)
    local t = type(v)
    if t == "table" then
        out[#out + 1] = "{\n"
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            if type(a) == type(b) then return a < b end
            return type(a) == "number"
        end)
        for _, k in ipairs(keys) do
            out[#out + 1] = indent .. "  ["
            out[#out + 1] = type(k) == "string" and string.format("%q", k) or tostring(k)
            out[#out + 1] = "] = "
            ser(v[k], indent .. "  ", out)
            out[#out + 1] = ",\n"
        end
        out[#out + 1] = indent .. "}"
    elseif t == "string" then
        out[#out + 1] = string.format("%q", v)
    elseif t == "number" or t == "boolean" then
        out[#out + 1] = tostring(v)
    else
        out[#out + 1] = "nil"
    end
end

function util.serialize(v)
    local out = { "return " }
    ser(v, "", out)
    out[#out + 1] = "\n"
    return table.concat(out)
end

--- Load a serialized table; returns nil on missing/corrupt file.
function util.load_table(path)
    local s = util.read_file(path)
    if not s then return nil end
    local chunk = loadstring(s, "=" .. path)
    if not chunk then return nil end
    setfenv(chunk, {})
    local ok, res = pcall(chunk)
    if ok and type(res) == "table" then return res end
    return nil
end

function util.save_table(path, t)
    util.mkdir_p(util.dirname(path))
    return util.write_file(path, util.serialize(t))
end

function util.deep_copy(t)
    if type(t) ~= "table" then return t end
    local r = {}
    for k, v in pairs(t) do r[k] = util.deep_copy(v) end
    return r
end

return util
