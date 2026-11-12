--[[
"Set up from phone" screen: shows a QR code and a one-time code; the phone
opens a page served by the Kindle (tome/setup_server.lua), picks a provider
and pastes the key. The key is checked right away by listing the provider's
models (free).
--]]
local plugin = ...
local app = plugin.app
local QR = require("tome.qr")
local Server = require("tome.setup_server")
local UI = require("tome.ui.manager")
local W = require("tome.ui.widgets")

local Setup = {}
Setup.__index = Setup

function Setup.new()
    return setmetatable({ fullscreen = true, refresh_mode = "full", hits = {} }, Setup)
end

function Setup:_status(text, kind)
    self.status, self.status_kind = text, kind
    if self.ui then self.ui:set_dirty("partial") end
end

function Setup:_on_save(f)
    local Providers = plugin.Providers
    local preset
    for _, p in ipairs(Providers.PRESETS) do if p.id == f.provider then preset = p end end
    if not preset then return false, "Pick a provider." end
    local key = (f.key or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if not preset.no_key and key == "" then return false, "Paste your API key." end
    if #key > 512 then return false, "That doesn't look like an API key." end
    local model = (f.model or ""):gsub("%s", "")
    if model ~= "" and not model:match("^[%w%-%._:/]+$") then return false, "The model name has odd characters." end
    local url = (f.url or ""):gsub("%s", "")
    if preset.needs_url then
        if not url:match("^https?://[%w%-%.:%[%]]+") then return false, "Enter the server address, like http://192.168.1.20:11434/v1" end
    else
        url = ""
    end
    Providers.save_phone_setup(preset.id, key, model, url)
    self.saved = preset
    self:_status("Saved " .. preset.label .. ". Testing the key\226\128\166", "busy")
    -- test in the background: listing models costs nothing
    app:run_task(function()
        local ok, msg = Providers.verify(preset.id)
        if ok then
            local masked = app.keystore.mask(app.keystore:get(preset.id))
            self:_status("\226\156\147 " .. msg .. ".\nKey " .. masked .. " is stored on this Kindle.", "ok")
        else
            self:_status("\226\156\151 The key was saved, but the test failed:\n" .. tostring(msg), "error")
        end
        self.done = true
    end)
    return true
end

function Setup:on_show()
    self:start()
end

function Setup:start()
    self.done, self.saved = false, nil
    self.server = Server.new({
        app = app,
        providers = plugin.Providers.PRESETS,
        on_save = function(f) return self:_on_save(f) end,
        on_event = function(kind, text)
            if kind == "error" then self:_status("\226\156\151 " .. text, "error") end
            if kind == "stopped" and text == "timeout" and not self.saved then
                self:_status("Setup timed out after 10 minutes.", "error")
            end
            if self.ui then self.ui:set_dirty("partial") end
        end,
    })
    local url, code_or_err = self.server:start()
    if not url then
        self.server = nil
        self:_status(code_or_err, "error")
        return
    end
    self.url, self.code = url, code_or_err
    self.matrix = QR.encode(self.server:qr_url())
    self:_status("Waiting for your phone\226\128\166", "busy")
    self.task = app:run_task(function()
        while self.server and self.server:running() do
            self.server:step()
            if not UI.await(function() return true end) then break end
        end
    end)
end

function Setup:on_close()
    if self.server then self.server:stop("closed") end
    if self.task then self.task.cancel() end
end

function Setup:draw(c)
    local t = W.theme(self.ui)
    local pad = t.pad
    self.hits = {}
    c:fill_rect(0, 0, c.w, c.h, 255)
    c:text(t.title, "Set up AI recap", pad * 2, (t.bar_h + t.title.ascent - t.title.descent) / 2)
    c:text(t.title, "\195\151", c.w - t.bar_h + (t.bar_h - t.title:width("\195\151")) / 2,
        (t.bar_h + t.title.ascent - t.title.descent) / 2)
    self.hits[#self.hits + 1] = { x = c.w - t.bar_h, y = 0, w = t.bar_h, h = t.bar_h, fn = function() self.ui:close(self) end }
    c:fill_rect(0, t.bar_h - t.border, c.w, t.border, 0)

    local y = t.bar_h + pad * 2
    local function para(text, font, color)
        font = font or t.font
        for _, l in ipairs(W.wrap(font, text, c.w - 4 * pad)) do
            c:text(font, l, pad * 2, y + font.ascent, color)
            y = y + font.line_height
        end
        y = y + pad
    end
    if self.matrix and not self.done then
        para("1. Scan this code with your phone's camera.")
        local size = math.floor(math.min(c.w * 0.62, c.h * 0.42))
        local drawn = QR.draw(c, self.matrix, (c.w - size) / 2, y, size)
        y = y + drawn + pad
        para("2. Choose your provider, paste your API key, and tap Save.")
        para("No camera? On your phone, open " .. self.url .. " and enter the code " .. self.code .. ".", t.small, 80)
        para("Your phone must be on the same Wi-Fi as this Kindle. The page closes when you leave this screen.", t.small, 110)
    end
    if self.status then
        local color = self.status_kind == "error" and 0 or 0
        y = y + pad
        for _, l in ipairs(W.wrap(t.bold, self.status, c.w - 4 * pad)) do
            c:text(t.bold, l, pad * 2, y + t.bold.ascent, color)
            y = y + t.bold.line_height
        end
        y = y + pad * 2
    end
    if self.done or (self.status_kind == "error" and not self.server) or (self.server and not self.server:running() and not self.saved) then
        local bw = math.floor(c.w * 0.4)
        local again = { x = pad * 2, y = y, w = bw, h = t.row_h }
        W.draw_button(c, again, "Set up again", t.bold, false, t.border)
        self.hits[#self.hits + 1] = { x = again.x, y = again.y, w = again.w, h = again.h, fn = function()
            if self.server then self.server:stop("restart") end
            self:start()
        end }
        local done = { x = c.w - pad * 2 - bw, y = y, w = bw, h = t.row_h }
        W.draw_button(c, done, "Done", t.bold, true, t.border)
        self.hits[#self.hits + 1] = { x = done.x, y = done.y, w = done.w, h = done.h, fn = function() self.ui:close(self) end }
    end
end

function Setup:handle(ev)
    if ev.type == "tap" then
        for i = #self.hits, 1, -1 do
            if W.inside(ev, self.hits[i]) then self.hits[i].fn(); self.ui:set_dirty("partial"); return true end
        end
    elseif ev.type == "key" and ev.key == "back" then
        self.ui:close(self)
    end
    return true
end

return Setup
