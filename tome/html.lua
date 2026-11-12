--[[
XHTML content document -> list of text blocks.

block = {
  kind  = "p" | "h" | "pre" | "quote" | "li" | "hr",
  level = heading level (kind "h"),
  runs  = { {text=, style=} ... }  style: "r" | "i" | "b" | "bi"
  text  = concatenated plain text of runs (byte offsets index into this)
}
ids[anchor] = block index, for TOC fragments.
--]]
local xml = require("tome.xml")

local html = {}

local BLOCK = {
    p = "p", div = "p", section = "p", article = "p", header = "p", footer = "p",
    main = "p", body = "p", figure = "p", figcaption = "p", center = "p",
    h1 = "h", h2 = "h", h3 = "h", h4 = "h", h5 = "h", h6 = "h",
    li = "li", dt = "p", dd = "quote", blockquote = "quote", pre = "pre",
    tr = "p", td = "p", th = "p", caption = "p", address = "p",
    ul = "p", ol = "p", dl = "p", table = "p",
}
local SKIP = { head = true, script = true, style = true, svg = true, math = true,
    title = true, rt = true, rp = true }
local ITALIC = { i = true, em = true, cite = true, var = true, dfn = true }
local BOLD = { b = true, strong = true }

local function style_of(i, b)
    if i > 0 and b > 0 then return "bi" end
    if i > 0 then return "i" end
    if b > 0 then return "b" end
    return "r"
end

function html.parse(source)
    local blocks, ids = {}, {}
    local cur = nil
    local italic, bold = 0, 0
    local skip_depth, skip_tag = 0, nil
    local pre_depth = 0
    local kind_stack = {}
    local pending_ids = {}

    local function flush()
        if cur then
            -- trim trailing whitespace of last run
            local last = cur.runs[#cur.runs]
            if last and pre_depth == 0 then last.text = last.text:gsub("%s+$", "") end
            while #cur.runs > 0 and cur.runs[#cur.runs].text == "" do cur.runs[#cur.runs] = nil end
            if #cur.runs > 0 then
                local parts = {}
                for i, r in ipairs(cur.runs) do parts[i] = r.text end
                cur.text = table.concat(parts)
                if cur.text:find("%S") then
                    blocks[#blocks + 1] = cur
                    for _, id in ipairs(pending_ids) do ids[id] = #blocks end
                    pending_ids = {}
                end
            end
        end
        cur = nil
    end

    local function current_kind()
        for i = #kind_stack, 1, -1 do
            if kind_stack[i].kind ~= "p" then return kind_stack[i] end
        end
        return kind_stack[#kind_stack] or { kind = "p" }
    end

    local function add_text(t)
        if pre_depth == 0 then
            t = t:gsub("[\t\r\n ]+", " ")
        end
        if t == "" then return end
        if not cur then
            if pre_depth == 0 then t = t:gsub("^ +", "") end
            if t == "" then return end
            local k = current_kind()
            cur = { kind = k.kind, level = k.level, runs = {} }
        end
        local st = style_of(italic, bold)
        local last = cur.runs[#cur.runs]
        if pre_depth == 0 and last and last.text:match("[ \n]$") and t:sub(1, 1) == " " then
            t = t:sub(2)
        end
        if last and last.style == st then
            last.text = last.text .. t
        else
            cur.runs[#cur.runs + 1] = { text = t, style = st }
        end
    end

    for kind, name, attrs, sc in xml.tokens(source) do
        if kind == "open" then
            if skip_depth > 0 then
                if not sc and name == skip_tag then skip_depth = skip_depth + 1 end
            elseif SKIP[name] or (attrs["epub:type"] or attrs["type"] or ""):find("footnote") then
                if not sc then skip_depth, skip_tag = 1, name end
            else
                if attrs.id then pending_ids[#pending_ids + 1] = attrs.id end
                if name == "br" then
                    if cur then
                        local last = cur.runs[#cur.runs]
                        last.text = last.text:gsub(" +$", "") .. "\n"
                    end
                elseif name == "hr" then
                    flush()
                    blocks[#blocks + 1] = { kind = "hr", runs = {}, text = "" }
                elseif name == "img" or name == "image" then
                    local alt = attrs.alt
                    if alt and alt:find("%S") then add_text(" [" .. alt .. "] ") end
                elseif BLOCK[name] then
                    flush()
                    if not sc then
                        kind_stack[#kind_stack + 1] = { tag = name, kind = BLOCK[name], level = tonumber(name:match("^h(%d)$")) }
                        if name == "pre" then pre_depth = pre_depth + 1 end
                    end
                elseif ITALIC[name] then
                    if not sc then italic = italic + 1 end
                elseif BOLD[name] then
                    if not sc then bold = bold + 1 end
                end
            end
        elseif kind == "close" then
            if skip_depth > 0 then
                if name == skip_tag then skip_depth = skip_depth - 1 end
            elseif BLOCK[name] then
                flush()
                for i = #kind_stack, 1, -1 do
                    if kind_stack[i].tag == name then
                        for j = #kind_stack, i, -1 do kind_stack[j] = nil end
                        break
                    end
                end
                if name == "pre" and pre_depth > 0 then pre_depth = pre_depth - 1 end
            elseif ITALIC[name] then
                italic = math.max(0, italic - 1)
            elseif BOLD[name] then
                bold = math.max(0, bold - 1)
            end
        else
            if skip_depth == 0 then add_text(name) end
        end
    end
    flush()
    return blocks, ids
end

return html
