--[[
Minimal read-only ZIP reader (stored + deflate), enough for EPUB.
--]]
local inflate = require("tome.inflate")

local Zip = {}
Zip.__index = Zip

local function u16(s, i) local a, b = s:byte(i, i + 1); return a + b * 256 end
local function u32(s, i) local a, b, c, d = s:byte(i, i + 3); return a + b * 256 + c * 65536 + d * 16777216 end

function Zip.open(path)
    local f, err = io.open(path, "rb")
    if not f then return nil, err end
    local size = f:seek("end")
    -- End of central directory: within the last 64 KiB + 22 bytes.
    local tail_len = math.min(size, 65557)
    f:seek("set", size - tail_len)
    local tail = f:read(tail_len)
    local eocd
    for i = #tail - 21, 1, -1 do
        if tail:byte(i) == 0x50 and tail:sub(i, i + 3) == "PK\5\6" then eocd = i; break end
    end
    if not eocd then f:close(); return nil, "not a zip file" end
    local count = u16(tail, eocd + 10)
    local cd_size = u32(tail, eocd + 12)
    local cd_off = u32(tail, eocd + 16)
    f:seek("set", cd_off)
    local cd = f:read(cd_size)
    if not cd or #cd < cd_size then f:close(); return nil, "truncated central directory" end

    local self = setmetatable({ file = f, path = path, entries = {}, order = {} }, Zip)
    local p = 1
    for _ = 1, count do
        if cd:sub(p, p + 3) ~= "PK\1\2" then break end
        local method = u16(cd, p + 10)
        local csize = u32(cd, p + 20)
        local usize = u32(cd, p + 24)
        local nlen = u16(cd, p + 28)
        local xlen = u16(cd, p + 30)
        local clen = u16(cd, p + 32)
        local loff = u32(cd, p + 42)
        local name = cd:sub(p + 46, p + 45 + nlen)
        local e = { name = name, method = method, csize = csize, usize = usize, offset = loff }
        self.entries[name] = e
        self.order[#self.order + 1] = name
        p = p + 46 + nlen + xlen + clen
    end
    return self
end

function Zip:has(name) return self.entries[name] ~= nil end

--- Read an entry by name (case-sensitive, falls back to case-insensitive).
function Zip:read(name)
    local e = self.entries[name]
    if not e then
        local lname = name:lower()
        for n, entry in pairs(self.entries) do
            if n:lower() == lname then e = entry; break end
        end
    end
    if not e then return nil, "no such entry: " .. name end
    local f = self.file
    f:seek("set", e.offset)
    local lh = f:read(30)
    if not lh or lh:sub(1, 4) ~= "PK\3\4" then return nil, "bad local header" end
    f:seek("cur", u16(lh, 27) + u16(lh, 29))
    local data = f:read(e.csize) or ""
    if e.method == 0 then return data end
    if e.method == 8 then
        local ok, res = pcall(inflate.inflate, data, e.usize)
        if not ok then return nil, res end
        return res
    end
    return nil, "unsupported compression method " .. e.method
end

function Zip:close()
    if self.file then self.file:close(); self.file = nil end
end

return Zip
