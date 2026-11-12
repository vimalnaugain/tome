--[[
HTTP client built on the device's `curl` binary (present on Kindle firmware
5.x), so Tome needs no TLS library of its own.

Requests run curl in the background and the calling task waits with
UI.await, so the screen and the Cancel button stay responsive. Headers and
body go through a mode-600 curl config file, never the command line, so API
keys do not show up in `ps`.
--]]
local UI = require("tome.ui.manager")
local util = require("tome.util")
local json = require("tome.json")
local log = require("tome.log")

local Http = {}
Http.__index = Http

local counter = 0

local function trim_or_nil(s)
    if not s then return nil end
    s = util.trim(s)
    if s == "" then return nil end
    return s
end

function Http.new(opts)
    opts = opts or {}
    return setmetatable({
        curl = opts.curl or "curl",
        ca_bundle = opts.ca_bundle,
        tmp_dir = opts.tmp_dir or "/tmp",
        user_agent = opts.user_agent or "Tome/0.1",
    }, Http)
end

local function cfg_quote(s)
    return '"' .. tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
end

--- req = { url, method="POST", headers={k=v}, body=string|table(json), timeout=seconds }
-- Returns { status = number, body = string, json = table|nil } or nil, error.
-- Inside a UI task this yields; elsewhere it blocks.
function Http:request(req)
    counter = counter + 1
    local base = string.format("%s/tome_http_%d_%d", self.tmp_dir, os.time(), counter)
    local files = { cfg = base .. ".cfg", body = base .. ".body", out = base .. ".out",
        code = base .. ".code", err = base .. ".err", done = base .. ".done", pid = base .. ".pid" }
    local body = req.body
    local headers = req.headers or {}
    if type(body) == "table" then
        body = json.encode(body)
        headers["content-type"] = headers["content-type"] or "application/json"
    end

    local lines = {
        "url = " .. cfg_quote(req.url),
        "request = " .. cfg_quote(req.method or (body and "POST" or "GET")),
        "silent", "show-error",
        "max-time = " .. tostring(req.timeout or 120),
        "connect-timeout = 20",
        "user-agent = " .. cfg_quote(self.user_agent),
        "output = " .. cfg_quote(files.out),
        "write-out = " .. cfg_quote("%{http_code}"),
    }
    if self.ca_bundle then lines[#lines + 1] = "cacert = " .. cfg_quote(self.ca_bundle) end
    for k, v in pairs(headers) do lines[#lines + 1] = "header = " .. cfg_quote(k .. ": " .. v) end
    if body then
        util.write_file(files.body, body)
        lines[#lines + 1] = "data-binary = " .. cfg_quote("@" .. files.body)
    end
    -- Create the config readable by us only, since it contains credentials.
    os.execute("umask 077 && : > " .. util.shell_quote(files.cfg))
    local f = io.open(files.cfg, "w")
    if not f then return nil, "cannot write curl config in " .. self.tmp_dir end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()

    local q = util.shell_quote
    -- `done` is renamed into place so its appearance means "content written".
    local script = string.format("%s -K %s > %s 2> %s & echo $! > %s; wait $!; echo $? > %s.tmp; mv %s.tmp %s",
        q(self.curl), q(files.cfg), q(files.code), q(files.err), q(files.pid), q(files.done), q(files.done), q(files.done))
    os.execute("sh -c " .. q(script) .. " >/dev/null 2>&1 &")
    log.debug("http", req.method or "POST", req.url)

    local function cleanup()
        for _, p in pairs(files) do os.remove(p) end
    end
    local function kill()
        local pid = tonumber(util.read_file(files.pid) or "")
        if pid then os.execute("kill " .. pid .. " >/dev/null 2>&1") end
    end

    local ok = UI.await(function() return util.file_exists(files.done) end, kill)
    if not ok then
        kill()
        -- The shell writes `done` right after curl dies; wait for it so no
        -- temp file is left behind.
        local okc, core = pcall(require, "tomecore")
        for _ = 1, 40 do
            if util.file_exists(files.done) or not okc then break end
            core.sleep_ms(25)
        end
        cleanup()
        return nil, "cancelled"
    end
    local exit = tonumber((util.read_file(files.done) or ""):match("%d+") or "")
    local status = tonumber((util.read_file(files.code) or ""):match("%d+") or "") or 0
    local out = util.read_file(files.out) or ""
    local err = trim_or_nil(util.read_file(files.err))
    cleanup()
    if exit and exit ~= 0 then
        return nil, string.format("network error (curl exit %d)%s", exit, err and (": " .. err) or "")
    end
    local res = { status = status, body = out }
    if out:sub(1, 1) == "{" or out:sub(1, 1) == "[" then res.json = json.decode(out) end
    return res
end

return Http
