--[[
Image helpers: decode JPEG/PNG to grayscale, and resize.
An image is { w, h, buf = uint8_t[w*h] }.
--]]
local ffi = require("ffi")

local Image = {}

function Image.decode(data)
    if not data or #data < 8 then return nil, "empty image" end
    if data:sub(1, 2) == "\255\216" then return require("tome.image.jpeg").decode(data) end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then return require("tome.image.png").decode(data) end
    return nil, "unsupported image format"
end

--- Resize with area averaging (good quality when shrinking, which is the
-- usual case for covers); nearest-neighbour when enlarging.
function Image.resize(img, w, h)
    w, h = math.max(1, math.floor(w)), math.max(1, math.floor(h))
    local out = ffi.new("uint8_t[?]", w * h)
    local sw, sh, src = img.w, img.h, img.buf
    local fx, fy = sw / w, sh / h
    if fx <= 1 and fy <= 1 then
        for y = 0, h - 1 do
            local sy = math.min(sh - 1, math.floor(y * fy))
            for x = 0, w - 1 do out[y * w + x] = src[sy * sw + math.min(sw - 1, math.floor(x * fx))] end
        end
        return { w = w, h = h, buf = out }
    end
    for y = 0, h - 1 do
        local y0, y1 = math.floor(y * fy), math.max(math.floor(y * fy) + 1, math.floor((y + 1) * fy))
        y1 = math.min(y1, sh)
        for x = 0, w - 1 do
            local x0, x1 = math.floor(x * fx), math.max(math.floor(x * fx) + 1, math.floor((x + 1) * fx))
            x1 = math.min(x1, sw)
            local sum, cnt = 0, 0
            for yy = y0, y1 - 1 do
                local row = yy * sw
                for xx = x0, x1 - 1 do sum = sum + src[row + xx] end
                cnt = cnt + (x1 - x0)
            end
            out[y * w + x] = cnt > 0 and math.floor(sum / cnt + 0.5) or 255
        end
    end
    return { w = w, h = h, buf = out }
end

--- Size that fits (keeps aspect ratio) inside w x h.
function Image.fit_size(img, w, h)
    local s = math.min(w / img.w, h / img.h)
    return math.max(1, math.floor(img.w * s + 0.5)), math.max(1, math.floor(img.h * s + 0.5))
end

--- Scale to cover w x h completely, cropping the overflow (centered).
function Image.fill(img, w, h)
    local s = math.max(w / img.w, h / img.h)
    local scaled = Image.resize(img, math.ceil(img.w * s), math.ceil(img.h * s))
    local out = ffi.new("uint8_t[?]", w * h)
    local ox, oy = math.floor((scaled.w - w) / 2), math.floor((scaled.h - h) / 2)
    for y = 0, h - 1 do ffi.copy(out + y * w, scaled.buf + (y + oy) * scaled.w + ox, w) end
    return { w = w, h = h, buf = out }
end

--- Draw an image onto a canvas at (x, y), clipped.
function Image.draw(canvas, img, x, y)
    x, y = math.floor(x), math.floor(y)
    for row = 0, img.h - 1 do
        local cy = y + row
        if cy >= 0 and cy < canvas.h then
            local x0 = math.max(0, x)
            local x1 = math.min(canvas.w, x + img.w)
            if x1 > x0 then
                ffi.copy(canvas.buf + cy * canvas.w + x0, img.buf + row * img.w + (x0 - x), x1 - x0)
            end
        end
    end
end

return Image
