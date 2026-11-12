--[[
Tolerant XML/XHTML tokenizer. Not validating: EPUBs in the wild are often
sloppy, so we only need tags, attributes and text.

xml.tokens(s) yields: kind, name_or_text, attrs, self_closing
  kind = "open" | "close" | "text"
--]]
local json = require("tome.json")

local xml = {}

local ENTITIES = {
    amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = "\194\160",
    mdash = "\226\128\148", ndash = "\226\128\147", hellip = "\226\128\166",
    lsquo = "\226\128\152", rsquo = "\226\128\153", ldquo = "\226\128\156", rdquo = "\226\128\157",
    laquo = "\194\171", raquo = "\194\187", copy = "\194\169", reg = "\194\174",
    trade = "\226\132\162", shy = "", zwnj = "", zwj = "", thinsp = "\226\128\137",
    ensp = "\226\128\130", emsp = "\226\128\131", middot = "\194\183", bull = "\226\128\162",
    deg = "\194\176", eacute = "\195\169", egrave = "\195\168", aacute = "\195\161",
    agrave = "\195\160", iacute = "\195\173", oacute = "\195\179", uacute = "\195\186",
    ntilde = "\195\177", ccedil = "\195\167", uuml = "\195\188", ouml = "\195\182",
    auml = "\195\164", szlig = "\195\159", euml = "\195\171", iuml = "\195\175",
    ecirc = "\195\170", acirc = "\195\162", ocirc = "\195\180", ucirc = "\195\187",
    aelig = "\195\166", oelig = "\197\147", times = "\195\151", divide = "\195\183",
    sect = "\194\167", para = "\194\182", dagger = "\226\128\160", Dagger = "\226\128\161",
    prime = "\226\128\178", Prime = "\226\128\179", frac12 = "\194\189", frac14 = "\194\188",
    frac34 = "\194\190", iexcl = "\194\161", iquest = "\194\191", pound = "\194\163",
    euro = "\226\130\172", yen = "\194\165", cent = "\194\162",
}

function xml.decode_entities(s)
    if not s:find("&", 1, true) then return s end
    return (s:gsub("&(#?[xX]?)(%w+);", function(kind, name)
        if kind == "#" then
            local n = tonumber(name)
            return n and json.utf8_char(n) or nil
        elseif kind == "#x" or kind == "#X" then
            local n = tonumber(name, 16)
            return n and json.utf8_char(n) or nil
        end
        return ENTITIES[name]
    end))
end

local function parse_attrs(s)
    local attrs = {}
    for k, q, v in s:gmatch("([%w_:%.%-]+)%s*=%s*([\"'])(.-)%2") do
        attrs[k:lower()] = xml.decode_entities(v)
        local local_name = k:match(":(.+)$")
        if local_name and attrs[local_name:lower()] == nil then attrs[local_name:lower()] = attrs[k:lower()] end
        local _ = q
    end
    return attrs
end

--- Local (namespace-stripped, lowercased) tag name.
local function local_name(name)
    return (name:match(":(.+)$") or name):lower()
end

function xml.tokens(s)
    return coroutine.wrap(function()
        local pos = 1
        local n = #s
        while pos <= n do
            local lt = s:find("<", pos, true)
            if not lt then
                coroutine.yield("text", xml.decode_entities(s:sub(pos)))
                break
            end
            if lt > pos then coroutine.yield("text", xml.decode_entities(s:sub(pos, lt - 1))) end
            if s:sub(lt, lt + 3) == "<!--" then
                local e = s:find("-->", lt + 4, true)
                pos = e and e + 3 or n + 1
            elseif s:sub(lt, lt + 8) == "<![CDATA[" then
                local e = s:find("]]>", lt + 9, true)
                coroutine.yield("text", s:sub(lt + 9, (e or n + 1) - 1))
                pos = e and e + 3 or n + 1
            elseif s:sub(lt + 1, lt + 1) == "?" or s:sub(lt + 1, lt + 1) == "!" then
                local e = s:find(">", lt, true)
                pos = e and e + 1 or n + 1
            else
                -- Find the closing '>' while respecting quoted attribute values.
                local i = lt + 1
                local q = nil
                while i <= n do
                    local c = s:sub(i, i)
                    if q then
                        if c == q then q = nil end
                    elseif c == '"' or c == "'" then
                        q = c
                    elseif c == ">" then
                        break
                    end
                    i = i + 1
                end
                local body = s:sub(lt + 1, i - 1)
                pos = i + 1
                if body:sub(1, 1) == "/" then
                    coroutine.yield("close", local_name(body:match("^/%s*([^%s>]+)") or ""))
                else
                    local name = body:match("^([^%s/>]+)")
                    if name then
                        local self_closing = body:sub(-1) == "/"
                        coroutine.yield("open", local_name(name), parse_attrs(body:sub(#name + 1)), self_closing)
                    end
                end
            end
        end
    end)
end

--- Very small DOM for OPF/NCX/container files: { name=, attrs=, children=, text= }.
function xml.parse_tree(s)
    local root = { name = "#root", attrs = {}, children = {} }
    local stack = { root }
    for kind, name, attrs, sc in xml.tokens(s) do
        local top = stack[#stack]
        if kind == "open" then
            local node = { name = name, attrs = attrs, children = {}, parent = top }
            top.children[#top.children + 1] = node
            if not sc then stack[#stack + 1] = node end
        elseif kind == "close" then
            for i = #stack, 2, -1 do
                if stack[i].name == name then
                    for j = #stack, i, -1 do stack[j] = nil end
                    break
                end
            end
        else
            top.children[#top.children + 1] = { text = name }
        end
    end
    return root
end

function xml.find_all(node, name, out)
    out = out or {}
    for _, c in ipairs(node.children or {}) do
        if c.name == name then out[#out + 1] = c end
        if c.children then xml.find_all(c, name, out) end
    end
    return out
end

function xml.find(node, name)
    for _, c in ipairs(node.children or {}) do
        if c.name == name then return c end
        if c.children then
            local r = xml.find(c, name)
            if r then return r end
        end
    end
end

function xml.text(node)
    if node.text then return node.text end
    local parts = {}
    for _, c in ipairs(node.children or {}) do parts[#parts + 1] = xml.text(c) end
    return table.concat(parts)
end

return xml
