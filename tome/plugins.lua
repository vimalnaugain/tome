--[[
Plugin loader. Mirrors KOReader's PluginLoader (frontend/pluginloader.lua)
in shape -- a directory per plugin with _meta.lua + main.lua -- but with a
small, explicit API instead of KOReader's widget tree. See docs/PLUGIN_API.md.

  plugins/<name>.plugin/_meta.lua   return { name=, fullname=, description=, version=, api=1 }
  plugins/<name>.plugin/main.lua    return Plugin  (a table of methods)

Each plugin instance gets: self.app, self.name, self.dir, self.settings,
self:require(module) for files in its own directory.
--]]
local util = require("tome.util")
local log = require("tome.log")

local API_VERSION = 1

local Plugins = { API_VERSION = API_VERSION }
Plugins.__index = Plugins

function Plugins.new(app)
    return setmetatable({ app = app, list = {}, by_name = {} }, Plugins)
end

local function load_chunk(path, env_name)
    local chunk, err = loadfile(path)
    if not chunk then return nil, err end
    local ok, res = pcall(chunk)
    if not ok then return nil, res end
    return res
end

--- Plugin-local require: plugin:require("providers") -> <dir>/providers.lua
local function plugin_require(self, name)
    self._modules = self._modules or {}
    if self._modules[name] ~= nil then return self._modules[name] end
    local path = self.dir .. "/" .. name:gsub("%.", "/") .. ".lua"
    local chunk, err = loadfile(path)
    if not chunk then error("plugin " .. self.name .. ": " .. tostring(err), 2) end
    local mod = chunk(self)
    if mod == nil then mod = true end
    self._modules[name] = mod
    return mod
end

function Plugins:load_dir(root)
    local disabled = self.app.settings.plugins_disabled or {}
    for _, e in ipairs(util.list_dir(root)) do
        local short = e.name:match("^(.+)%.plugin$")
        if e.is_dir and short then
            local dir = root .. "/" .. e.name
            local meta, merr = load_chunk(dir .. "/_meta.lua")
            if not meta then
                log.error("plugin", short, "bad _meta.lua:", merr)
            elseif disabled[short] or meta.disabled then
                log.info("plugin", short, "disabled")
            elseif (meta.api or 1) > API_VERSION then
                log.warn("plugin", short, "needs API", meta.api, "but Tome provides", API_VERSION)
            elseif self.by_name[meta.name or short] then
                log.warn("plugin", short, "already loaded; skipping", dir)
            else
                local class, err = load_chunk(dir .. "/main.lua")
                if type(class) ~= "table" then
                    log.error("plugin", short, "failed to load:", err or "main.lua must return a table")
                else
                    local name = meta.name or short
                    local inst = setmetatable({
                        app = self.app, name = name, dir = dir, meta = meta,
                        settings = self.app:plugin_settings(name),
                        require = plugin_require,
                    }, { __index = class })
                    local ok, ierr = true, nil
                    if inst.init then ok, ierr = pcall(inst.init, inst) end
                    if ok then
                        self.list[#self.list + 1] = inst
                        self.by_name[name] = inst
                        log.info("plugin loaded:", name, meta.version or "")
                    else
                        log.error("plugin", name, "init failed:", ierr)
                    end
                end
            end
        end
    end
end

--- Call plugin["on" .. event](plugin, ...) on every plugin, isolating errors.
function Plugins:broadcast(event, ...)
    local method = "on" .. event
    for _, p in ipairs(self.list) do
        local fn = p[method]
        if fn then
            local ok, err = pcall(fn, p, ...)
            if not ok then log.error("plugin", p.name, method, "failed:", err) end
        end
    end
end

--- Let plugins append menu entries: plugin:addToReaderMenu(items, reader)
function Plugins:collect_menu(where, items, ctx)
    local method = "addTo" .. where .. "Menu"
    for _, p in ipairs(self.list) do
        local fn = p[method]
        if fn then
            local ok, err = pcall(fn, p, items, ctx)
            if not ok then log.error("plugin", p.name, method, "failed:", err) end
        end
    end
end

return Plugins
