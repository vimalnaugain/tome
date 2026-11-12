--[[
SDL2 window for desktop development (LuaJIT FFI; not used on Kindle).
--]]
local ffi = require("ffi")
local Gestures = require("tome.device.gestures")

ffi.cdef[[
typedef struct SDL_Window SDL_Window;
typedef struct SDL_Renderer SDL_Renderer;
typedef struct SDL_Texture SDL_Texture;
typedef union SDL_Event { uint32_t type; uint8_t padding[56]; } SDL_Event;
typedef struct { uint32_t type; uint32_t timestamp; uint32_t windowID; uint8_t state; uint8_t repeat_;
  uint8_t p2; uint8_t p3; int32_t scancode; int32_t sym; uint16_t mod; uint32_t unused; } SDL_KeyboardEvent;
typedef struct { uint32_t type; uint32_t timestamp; uint32_t windowID; uint32_t which; uint8_t button;
  uint8_t state; uint8_t clicks; uint8_t padding1; int32_t x; int32_t y; } SDL_MouseButtonEvent;
typedef struct { uint32_t type; uint32_t timestamp; uint32_t windowID; uint32_t which; uint32_t state;
  int32_t x; int32_t y; int32_t xrel; int32_t yrel; } SDL_MouseMotionEvent;
int SDL_Init(uint32_t flags);
SDL_Window* SDL_CreateWindow(const char*, int, int, int, int, uint32_t);
SDL_Renderer* SDL_CreateRenderer(SDL_Window*, int, uint32_t);
SDL_Texture* SDL_CreateTexture(SDL_Renderer*, uint32_t, int, int, int);
int SDL_UpdateTexture(SDL_Texture*, const void*, const void*, int);
int SDL_RenderClear(SDL_Renderer*);
int SDL_RenderCopy(SDL_Renderer*, SDL_Texture*, const void*, const void*);
void SDL_RenderPresent(SDL_Renderer*);
int SDL_WaitEventTimeout(SDL_Event*, int);
int SDL_PollEvent(SDL_Event*);
uint32_t SDL_GetTicks(void);
void SDL_Quit(void);
]]

local SDL_INIT_VIDEO = 0x20
local SDL_WINDOWPOS_CENTERED = 0x2FFF0000
local SDL_PIXELFORMAT_RGB888 = 0x16161804
local SDL_TEXTUREACCESS_STREAMING = 1
local QUIT, KEYDOWN, MOUSEDOWN, MOUSEUP, MOUSEMOTION = 0x100, 0x300, 0x401, 0x402, 0x400
local KEYS = {
    [0x4000004F] = "next", [0x40000050] = "prev", [0x4000004E] = "next", [0x4000004B] = "prev",
    [0x40000051] = "down", [0x40000052] = "up", [27] = "back", [109] = "menu", [13] = "select", [113] = "quit",
}

local SDL = {}
SDL.__index = SDL

function SDL.new(w, h, scale)
    local lib = ffi.load("SDL2-2.0.so.0")
    assert(lib.SDL_Init(SDL_INIT_VIDEO) == 0, "SDL_Init failed")
    local self = setmetatable({ lib = lib, w = w, h = h, scale = scale }, SDL)
    self.win = lib.SDL_CreateWindow("Tome", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        math.floor(w * scale), math.floor(h * scale), 0)
    self.ren = lib.SDL_CreateRenderer(self.win, -1, 0)
    self.tex = lib.SDL_CreateTexture(self.ren, SDL_PIXELFORMAT_RGB888, SDL_TEXTUREACCESS_STREAMING, w, h)
    self.rgb = ffi.new("uint32_t[?]", w * h)
    self.ev = ffi.new("SDL_Event")
    self.gestures = Gestures.new({ tap_slop = 20 })
    return self
end

function SDL:present(canvas)
    local n = self.w * self.h
    local src, dst = canvas.buf, self.rgb
    for i = 0, n - 1 do
        local v = src[i]
        dst[i] = v * 65793 -- 0x010101
    end
    self.lib.SDL_UpdateTexture(self.tex, nil, dst, self.w * 4)
    self.lib.SDL_RenderClear(self.ren)
    self.lib.SDL_RenderCopy(self.ren, self.tex, nil, nil)
    self.lib.SDL_RenderPresent(self.ren)
end

function SDL:poll(timeout_ms)
    local out = {}
    local lib, ev = self.lib, self.ev
    if lib.SDL_WaitEventTimeout(ev, timeout_ms or 100) == 0 then return out end
    repeat
        local t = ev.type
        if t == QUIT then
            out[#out + 1] = { type = "quit" }
        elseif t == KEYDOWN then
            local k = ffi.cast("SDL_KeyboardEvent*", ev)
            local name = KEYS[k.sym]
            if name == "quit" then out[#out + 1] = { type = "quit" }
            elseif name then out[#out + 1] = { type = "key", key = name } end
        elseif t == MOUSEDOWN or t == MOUSEUP then
            local m = ffi.cast("SDL_MouseButtonEvent*", ev)
            local x, y = math.floor(m.x / self.scale), math.floor(m.y / self.scale)
            if t == MOUSEDOWN then
                self.right = m.button == 3
                self.gestures:touch_down(x, y, lib.SDL_GetTicks())
            else
                local g = self.gestures:touch_up(lib.SDL_GetTicks())
                if g and self.right and g.type == "tap" then g.type = "hold" end
                if g then out[#out + 1] = g end
            end
        elseif t == MOUSEMOTION then
            local m = ffi.cast("SDL_MouseMotionEvent*", ev)
            self.gestures:touch_move(math.floor(m.x / self.scale), math.floor(m.y / self.scale))
        end
    until lib.SDL_PollEvent(ev) == 0
    return out
end

function SDL:close() self.lib.SDL_Quit() end

return SDL
