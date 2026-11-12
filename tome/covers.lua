--[[
Cover cache. Decoding a cover takes about a second on a Kindle, so each book's
cover is decoded once, stored as a screen-sized grayscale "master", and every
other size is made from that master and cached too.

Files in <data_dir>/covers/:
  <id>.master.gray      largest needed size
  <id>_<w>x<h>_<mode>.gray
  <id>.none             the book has no usable cover (don't try again)
--]]
local ffi = require("ffi")
local Image = require("tome.image")
local Epub = require("tome.epub")
local util = require("tome.util")
local log = require("tome.log")

local Covers = {}
Covers.__index = Covers

function Covers.new(app)
    local self = setmetatable({ app = app, dir = app.data_dir .. "/covers", mem = {}, mem_order = {} }, Covers)
    util.mkdir_p(self.dir)
    return self
end

local function save_gray(path, img)
    local header = string.format("TGRY%6d%6d", img.w, img.h)
    util.write_file(path, header .. ffi.string(img.buf, img.w * img.h))
end

local function load_gray(path)
    local s = util.read_file(path)
    if not s or s:sub(1, 4) ~= "TGRY" then return nil end
    local w, h = tonumber(s:sub(5, 10)), tonumber(s:sub(11, 16))
    if not w or not h or #s < 16 + w * h then return nil end
    local buf = ffi.new("uint8_t[?]", w * h)
    ffi.copy(buf, ffi.cast("const uint8_t*", s) + 16, w * h)
    return { w = w, h = h, buf = buf }
end

function Covers:_remember(key, img)
    if not self.mem[key] then
        self.mem_order[#self.mem_order + 1] = key
        if #self.mem_order > 24 then
            self.mem[table.remove(self.mem_order, 1)] = nil
        end
    end
    self.mem[key] = img
end

function Covers:has_none(id) return util.file_exists(self.dir .. "/" .. id .. ".none") end
function Covers:has_master(id) return util.file_exists(self.dir .. "/" .. id .. ".master.gray") end

--- Decode the book's cover and store the master. Slow; call from a task or
-- when the user is waiting anyway. Returns true if a cover is available.
--- Title and authors read from the EPUB (cached), for books not opened yet.
function Covers:meta(id)
    return util.load_table(self.dir .. "/" .. id .. ".meta.lua")
end

function Covers:prepare(path, id)
    if self:has_master(id) then return true end
    if self:has_none(id) then return false end
    local t0 = os.clock()
    local doc = Epub.open(path)
    local data = doc and doc:cover_data()
    if doc then
        util.save_table(self.dir .. "/" .. id .. ".meta.lua", { title = doc.title, authors = doc.authors })
        doc:close()
    end
    local img, err
    if data then img, err = Image.decode(data) else err = "no cover image" end
    if not img then
        log.info("cover:", util.basename(path), err)
        util.write_file(self.dir .. "/" .. id .. ".none", tostring(err))
        return false
    end
    -- master: big enough for a full-screen sleep cover in either orientation
    local d = self.app.device
    local long = math.max(d.phys_w or d.width, d.phys_h or d.height)
    if img.w > long or img.h > long then img = Image.resize(img, Image.fit_size(img, long, long)) end
    save_gray(self.dir .. "/" .. id .. ".master.gray", img)
    log.debug(string.format("cover: %s decoded in %.2fs", util.basename(path), os.clock() - t0))
    return true
end

--- Cover at a given size, from the cache. mode "fit" keeps the whole cover
-- (result may be smaller than w x h); "fill" covers w x h exactly, cropping.
-- Returns nil if there is no cover or it hasn't been prepared yet.
function Covers:get(id, w, h, mode)
    mode = mode or "fit"
    w, h = math.floor(w), math.floor(h)
    local key = string.format("%s_%dx%d_%s", id, w, h, mode)
    if self.mem[key] then return self.mem[key] end
    local file = self.dir .. "/" .. key .. ".gray"
    local img = load_gray(file)
    if not img then
        local master = load_gray(self.dir .. "/" .. id .. ".master.gray")
        if not master then return nil end
        if mode == "fill" then img = Image.fill(master, w, h)
        else img = Image.resize(master, Image.fit_size(master, w, h)) end
        save_gray(file, img)
    end
    self:_remember(key, img)
    return img
end

--- Prepare covers for a list of {path, id} in the background, calling
-- on_ready(id) after each one so the screen can update, and on_done()
-- at the end.
function Covers:prepare_all(list, on_ready, on_done)
    local UI = require("tome.ui.manager")
    return self.app:run_task(function()
        -- let the screen paint first; decode one cover per UI tick
        if not UI.await(function() return true end) then return end
        for _, b in ipairs(list) do
            if not self:has_master(b.id) and not self:has_none(b.id) then
                local ok, res = pcall(self.prepare, self, b.path, b.id)
                if not ok then log.warn("cover failed:", res) end
                if on_ready then on_ready(b.id) end
                if not UI.await(function() return true end) then return end
            end
        end
        if on_done then on_done() end
    end)
end

return Covers
