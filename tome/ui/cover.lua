--[[
Draws a book's cover in a box: the real cover image when the book has one
(and it has been prepared), otherwise a typographic tile with the title.
Used by the home screen, the library and the sleep screen.
--]]
local Font = require("tome.font")
local Image = require("tome.image")
local W = require("tome.ui.widgets")

local Cover = {}

--- Typographic stand-in: title and author set in a framed tile.
function Cover.tile(c, x, y, w, h, title, author)
    local border = math.max(1, math.floor(w / 110))
    c:fill_rect(x, y, w, h, 238)
    c:rect(x, y, w, h, 0, border)
    if w < 120 then
        -- too small for text: a few "title lines" suggest a book
        for i, frac in ipairs({ 0.6, 0.45, 0.3 }) do
            local lw = math.floor(w * frac)
            c:fill_rect(x + (w - lw) / 2, y + h * (0.22 + i * 0.09), lw, math.max(2, math.floor(h / 40)), 90)
        end
        return
    end
    c:rect(x + border * 3, y + border * 3, w - border * 6, h - border * 6, 120, 1)
    local inner = w - math.max(8, border * 14)
    local font, lines
    for _, k in ipairs({ 0.13, 0.115, 0.1, 0.085, 0.07 }) do
        font = Font.get("serif", "b", math.max(14, math.floor(w * k)))
        lines = W.wrap(font, title or "", inner)
        if #lines <= 5 then break end
    end
    local maxl = math.max(1, math.min(#lines, math.floor(h * 0.6 / font.line_height)))
    local ty = y + math.floor(h * 0.22)
    for i = 1, maxl do
        local l = lines[i]
        c:text(font, l, x + (w - font:width(l)) / 2, ty + font.ascent * 0.5)
        ty = ty + font.line_height
    end
    if author and author ~= "" and h > 120 then
        local f = Font.get("serif", "i", math.max(12, math.floor(w * 0.065)))
        local a = W.fit(f, author, inner)
        c:text(f, a, x + (w - f:width(a)) / 2, y + h - border * 8, 60)
    end
end

local function authors_of(book)
    return (book.authors and #book.authors > 0) and table.concat(book.authors, ", ") or ""
end

--- book = { id, path, title, authors }
-- mode: "fill" (crop to the box, for tiles) or "fit" (whole cover, centered on white)
function Cover.draw(app, c, x, y, w, h, book, mode)
    x, y, w, h = math.floor(x), math.floor(y), math.floor(w), math.floor(h)
    local img = book.id and app.covers:get(book.id, w, h, mode or "fill")
    if img then
        Image.draw(c, img, x + math.floor((w - img.w) / 2), y + math.floor((h - img.h) / 2))
        if (mode or "fill") == "fill" then c:rect(x, y, w, h, 0, 1) end
        return true
    end
    Cover.tile(c, x, y, w, h, book.title, authors_of(book))
    return false
end

return Cover
