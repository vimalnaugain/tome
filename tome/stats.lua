--[[
Reading statistics: time spent reading (per day and per book), reading
speed (for "minutes left"), and which books were finished when.

Stored in <data_dir>/stats.lua:
  speed = { chars, seconds }            -- for chars-per-minute
  days  = { ["2026-11-12"] = seconds }
  books = { [book_id] = { title, authors, path, seconds, started, finished } }
--]]
local util = require("tome.util")

local Stats = {}
Stats.__index = Stats

-- ~220 words per minute until we have learned the reader's own pace.
local DEFAULT_CPM = 1100
local LEARN_AFTER_SECONDS = 10 * 60

function Stats.open(path)
    local self = setmetatable({ path = path }, Stats)
    self.data = util.load_table(path) or {}
    self.data.speed = self.data.speed or { chars = 0, seconds = 0 }
    self.data.days = self.data.days or {}
    self.data.books = self.data.books or {}
    self.dirty = 0
    return self
end

function Stats:save()
    util.save_table(self.path, self.data)
    self.dirty = 0
end

local function day_key(t) return os.date("%Y-%m-%d", t) end

function Stats:book(id, info)
    local b = self.data.books[id]
    if not b then
        b = { seconds = 0, started = os.time() }
        self.data.books[id] = b
    end
    if info then
        b.title, b.authors, b.path = info.title, info.authors, info.path
    end
    return b
end

--- Account for time spent on a page.
-- seconds: time since the previous page turn; chars: text on the page left
-- behind (only for forward turns, used to learn the reading speed).
function Stats:record(book_id, seconds, chars)
    if seconds < 1 or seconds > 600 then return end -- away from the device
    local counted = math.min(seconds, 180)
    local day = day_key(os.time())
    self.data.days[day] = (self.data.days[day] or 0) + counted
    local b = self:book(book_id)
    b.seconds = (b.seconds or 0) + counted
    if chars and chars > 200 and seconds >= 3 and seconds <= 180 then
        local sp = self.data.speed
        sp.chars, sp.seconds = sp.chars + chars, sp.seconds + seconds
    end
    self.dirty = self.dirty + 1
    if self.dirty >= 10 then self:save() end
end

--- Reading speed in characters per minute, blended with a default while learning.
function Stats:chars_per_minute()
    local sp = self.data.speed
    if sp.seconds <= 0 then return DEFAULT_CPM end
    local measured = sp.chars / sp.seconds * 60
    local w = math.min(1, sp.seconds / LEARN_AFTER_SECONDS)
    return measured * w + DEFAULT_CPM * (1 - w)
end

function Stats:set_finished(book_id, finished)
    local b = self:book(book_id)
    b.finished = finished and os.time() or nil
    self:save()
end

function Stats:is_finished(book_id)
    local b = self.data.books[book_id]
    return b and b.finished ~= nil
end

--- { finished = n, seconds = s } for a calendar year (default: this year).
function Stats:year(y)
    y = y or tonumber(os.date("%Y"))
    local finished = 0
    for _, b in pairs(self.data.books) do
        if b.finished and tonumber(os.date("%Y", b.finished)) == y then finished = finished + 1 end
    end
    local seconds = 0
    local prefix = tostring(y) .. "-"
    for day, s in pairs(self.data.days) do
        if day:sub(1, 5) == prefix then seconds = seconds + s end
    end
    return { finished = finished, seconds = seconds }
end

--- Seconds read over the last 7 days, including today.
function Stats:week_seconds()
    local total, now = 0, os.time()
    for i = 0, 6 do total = total + (self.data.days[day_key(now - i * 86400)] or 0) end
    return total
end

--- Consecutive days with some reading, ending today (or yesterday).
function Stats:streak_days()
    local now, n = os.time(), 0
    local start = (self.data.days[day_key(now)] or 0) > 0 and 0 or 1
    for i = start, 3650 do
        if (self.data.days[day_key(now - i * 86400)] or 0) >= 60 then n = n + 1 else break end
    end
    return n
end

--- "3 min", "1 h 05 min", "less than a minute"
function Stats.format_duration(seconds, short)
    seconds = math.max(0, seconds or 0)
    local m = math.floor(seconds / 60 + 0.5)
    if seconds == 0 then return "0 min" end
    if m < 1 then return short and "<1 min" or "less than a minute" end
    if m < 60 then return m .. " min" end
    local h = math.floor(m / 60)
    if short and h >= 10 then return h .. " h" end
    return string.format("%d h %02d min", h, m % 60)
end

return Stats
