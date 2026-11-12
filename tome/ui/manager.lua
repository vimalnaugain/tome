--[[
UI manager: a stack of views, the event loop, timers and cooperative tasks.

Modeled on KOReader's UIManager (frontend/ui/uimanager.lua) but much smaller:
  * views are drawn bottom-to-top into one Canvas, then pushed to the device;
  * input goes to the top-most view only (every overlay is modal);
  * tasks are coroutines that yield a "ready?" predicate, which lets plugins
    write linear code (e.g. several HTTP calls in a row) without blocking
    the screen or input.
--]]
local Canvas = require("tome.canvas")
local log = require("tome.log")

local UI = {}
UI.__index = UI

function UI.new(device)
    local self = setmetatable({
        device = device,
        stack = {},
        timers = {},
        tasks = {},
        dirty = "full",
        running = false,
    }, UI)
    self.canvas = Canvas.new(device.width, device.height)
    device.busy_fn = function() return #self.tasks > 0 or #self.timers > 0 end
    return self
end

--- Change orientation: new canvas size, theme recomputed, views re-layout.
function UI:set_rotation(r)
    if not self.device.set_rotation then return end
    self.device:set_rotation(r)
    self.canvas = Canvas.new(self.device.width, self.device.height)
    self.theme = nil
    for _, v in ipairs(self.stack) do
        if v.on_resize then
            local ok, err = pcall(v.on_resize, v)
            if not ok then log.error("resize failed:", err) end
        end
    end
    self:set_dirty("full")
end

function UI:show(view)
    self.stack[#self.stack + 1] = view
    view.ui = self
    if view.on_show then view:on_show() end
    self:set_dirty(view.refresh_mode or "partial")
    return view
end

function UI:close(view)
    for i = #self.stack, 1, -1 do
        if self.stack[i] == view then
            table.remove(self.stack, i)
            if view.on_close then view:on_close() end
            self:set_dirty(view.close_refresh or "partial")
            return true
        end
    end
    return false
end

function UI:top() return self.stack[#self.stack] end

--- Request a redraw. "full" flashes the e-ink panel (clears ghosting).
function UI:set_dirty(mode)
    if mode == "full" or self.dirty == nil or self.dirty == false then
        self.dirty = mode or "partial"
    end
end

--- Run fn after delay_ms. Returns a handle for cancel_timer.
function UI:schedule(delay_ms, fn)
    local t = { at = self.device:monotonic_ms() + delay_ms, fn = fn }
    self.timers[#self.timers + 1] = t
    return t
end

function UI:cancel_timer(t)
    for i, x in ipairs(self.timers) do
        if x == t then table.remove(self.timers, i); return end
    end
end

--- Start a cooperative task. Inside it, call UI.await(predicate) to wait.
-- Returns a handle with :cancel().
function UI:spawn(fn, on_error)
    local task = { co = coroutine.create(fn), on_error = on_error }
    task.cancel = function()
        task.cancelled = true
        if task.on_cancel then pcall(task.on_cancel) end
    end
    self.tasks[#self.tasks + 1] = task
    self:_step(task)
    return task
end

--- Yield the current task until predicate() returns true.
-- Must be called from inside UI:spawn. Returns false if the task was cancelled.
function UI.await(predicate, on_cancel)
    local co, is_main = coroutine.running()
    if not co or is_main then
        -- Not inside a task: block (used by tests and simple scripts).
        while not predicate() do os.execute("sleep 0.1") end
        return true
    end
    return coroutine.yield(predicate, on_cancel)
end

function UI:_step(task, resume_value)
    local ok, pred, on_cancel = coroutine.resume(task.co, resume_value)
    if not ok then
        log.error("task failed:", pred)
        if task.on_error then pcall(task.on_error, pred) end
        task.done = true
    elseif coroutine.status(task.co) == "dead" then
        task.done = true
    else
        task.waiting = pred
        task.on_cancel = on_cancel
    end
    if task.done then
        for i, t in ipairs(self.tasks) do if t == task then table.remove(self.tasks, i) break end end
    end
end

function UI:_run_tasks()
    for _, task in ipairs({ unpack(self.tasks) }) do
        if task.cancelled then
            -- resume with false so the task can clean up, then drop it
            self:_step(task, false)
        elseif task.waiting then
            local ok, ready = pcall(task.waiting)
            if not ok then
                log.error("task predicate failed:", ready)
                self:_step(task, false)
            elseif ready then
                task.waiting = nil
                self:_step(task, true)
            end
        end
    end
end

function UI:_run_timers()
    local now = self.device:monotonic_ms()
    local due = {}
    for i = #self.timers, 1, -1 do
        if self.timers[i].at <= now then
            due[#due + 1] = self.timers[i]
            table.remove(self.timers, i)
        end
    end
    for i = #due, 1, -1 do
        local ok, err = pcall(due[i].fn)
        if not ok then log.error("timer failed:", err) end
    end
end

function UI:repaint()
    local mode = self.dirty
    self.dirty = false
    self.canvas:clear(255)
    -- Start from the top-most full-screen view; anything below is hidden.
    local first = 1
    for i = #self.stack, 1, -1 do
        if self.stack[i].fullscreen then first = i; break end
    end
    for i = first, #self.stack do
        local v = self.stack[i]
        if v.draw then
            local ok, err = pcall(v.draw, v, self.canvas)
            if not ok then log.error("draw failed:", err) end
        end
    end
    self.device:refresh(self.canvas, mode)
end

function UI:dispatch(ev)
    if ev.type == "quit" then self:quit(); return end
    local v = self:top()
    if v and v.handle then
        local ok, err = pcall(v.handle, v, ev)
        if not ok then log.error("event handler failed:", err) end
    end
end

function UI:quit() self.running = false end

function UI:run()
    self.running = true
    while self.running do
        if self.dirty then self:repaint() end
        local timeout = 1000
        if #self.tasks > 0 then timeout = 200 end
        local now = self.device:monotonic_ms()
        for _, t in ipairs(self.timers) do timeout = math.min(timeout, math.max(0, t.at - now)) end
        for _, ev in ipairs(self.device:poll(math.floor(timeout))) do
            self:dispatch(ev)
            if not self.running then break end
        end
        self:_run_timers()
        self:_run_tasks()
    end
end

return UI
