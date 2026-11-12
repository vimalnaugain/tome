--[[
Tome entry point.

  Kindle:   ./tome main.lua                       (via platform/kindle/tome.sh)
  Desktop:  luajit main.lua [--emulator] [--script FILE] [--sdl] [book.epub]

  --home DIR   where config.lua and data/ live (default: next to main.lua).
               The KPM package uses /mnt/us/tome, so upgrades keep your data.
--]]
local root = arg and arg[0] and arg[0]:match("^(.*)/[^/]*$") or "."
package.path = root .. "/?.lua;" .. package.path
package.cpath = root .. "/native/?.so;" .. package.cpath

local log = require("tome.log")
local util = require("tome.util")

local opts = { root = root }
local book
local emu = {}
local i = 1
while arg and i <= #arg do
    local a = arg[i]
    if a == "--emulator" then opts.device = "emulator"
    elseif a == "--kindle" then opts.device = "kindle"
    elseif a == "--script" then i = i + 1; emu.script = arg[i]; opts.device = "emulator"
    elseif a == "--sdl" then emu.input = "sdl"; opts.device = "emulator"
    elseif a == "--out" then i = i + 1; emu.out_dir = arg[i]
    elseif a == "--config" then i = i + 1; opts.config_path = arg[i]
    elseif a == "--home" then i = i + 1; opts.home = arg[i]
    elseif a == "--debug" then log.set_level("debug")
    else book = a end
    i = i + 1
end

local home = opts.home or os.getenv("TOME_HOME") or root
local config_path = opts.config_path or (home .. "/config.lua")
local config = util.load_table(config_path)
if not config and util.file_exists(config_path) then
    log.error("config.lua has a syntax error; using defaults")
end
config = config or {}
config.data_dir = config.data_dir or (home .. "/data")
config.emulator = config.emulator or {}
for k, v in pairs(emu) do config.emulator[k] = v end
opts.config = config
if config.log_level then log.set_level(config.log_level) end
if config.log_file then log.set_file(config.log_file) end

local App = require("tome.app")
local app = App.new(opts)
local ok = app:run(book)
os.exit(ok and 0 or 1)
