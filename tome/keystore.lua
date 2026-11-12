--[[
API key store.

Keys live outside the USB-visible storage: on a Kindle in /var/local/tome
(the internal system partition), so plugging the Kindle into a computer
doesn't expose them. Files are created with mode 600. Keys are never
logged; use Keystore.mask() to show one.
--]]
local util = require("tome.util")

local Keystore = {}
Keystore.__index = Keystore

function Keystore.new(app)
    local dir = app.config.secure_dir
        or (app.device.is_kindle and "/var/local/tome" or (app.data_dir .. "/secure"))
    os.execute("umask 077 && mkdir -p " .. util.shell_quote(dir) .. " && chmod 700 " .. util.shell_quote(dir))
    return setmetatable({ dir = dir }, Keystore)
end

local function valid_name(name)
    return type(name) == "string" and name:match("^[%w_%-]+$") ~= nil
end

function Keystore:path(name)
    assert(valid_name(name), "bad key name")
    return self.dir .. "/" .. name .. ".key"
end

function Keystore:get(name)
    if not valid_name(name) then return nil end
    local s = util.read_file(self:path(name))
    if not s then return nil end
    s = util.trim(s)
    return s ~= "" and s or nil
end

function Keystore:set(name, key)
    local p = self:path(name)
    local tmp = p .. ".tmp"
    -- create empty with restrictive permissions before writing the secret
    os.execute("umask 077 && : > " .. util.shell_quote(tmp))
    local f = assert(io.open(tmp, "w"))
    f:write(key)
    f:close()
    os.execute("chmod 600 " .. util.shell_quote(tmp))
    assert(os.rename(tmp, p))
end

function Keystore:remove(name)
    if valid_name(name) then os.remove(self:path(name)) end
end

--- "AIza…3cde" style display: never show a whole key.
function Keystore.mask(key)
    if not key or key == "" then return "(none)" end
    if #key <= 10 then return string.rep("\226\128\162", 6) end
    return key:sub(1, 4) .. "\226\128\166" .. key:sub(-4)
end

return Keystore
