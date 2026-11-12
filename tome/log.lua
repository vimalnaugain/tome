local log = { level = 2, file = nil }

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }

function log.set_level(name) log.level = LEVELS[name] or 2 end

function log.set_file(path)
    log.file = io.open(path, "a")
    if log.file then log.file:setvbuf("line") end
end

local function emit(lvl, name, ...)
    if lvl < log.level then return end
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    local line = os.date("%H:%M:%S") .. " " .. name .. " " .. table.concat(parts, " ")
    io.stderr:write(line, "\n")
    if log.file then log.file:write(line, "\n") end
end

function log.debug(...) emit(1, "DEBUG", ...) end
function log.info(...) emit(2, "INFO ", ...) end
function log.warn(...) emit(3, "WARN ", ...) end
function log.error(...) emit(4, "ERROR", ...) end

return log
