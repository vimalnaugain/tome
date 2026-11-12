--[[
Phone setup server: a tiny web page served by the Kindle on the local Wi-Fi,
so an API key can be pasted on a phone instead of typed or copied in files.

Safety:
  * runs only while the setup screen is open; stops after one successful
    save, after 10 minutes, or after 5 wrong codes
  * every request needs a random 6-digit one-time code (in the QR link)
  * listens on the Wi-Fi address only; the Kindle firewall is opened for
    this one port and closed again when the server stops
  * Host header must match the Kindle's address (blocks DNS-rebinding
    tricks from web pages open on the phone)
  * small requests only (16 KB), 10 s per connection
  * pages carry no-store/no-referrer/CSP headers; keys never appear in
    URLs, logs or on screen (shown masked)
--]]
local ok_core, core = pcall(require, "tomecore")
local log = require("tome.log")
local bit = require("bit")

local Server = {}
Server.__index = Server

local MAX_REQUEST = 16384
local CONN_TIMEOUT_MS = 10000
local LIFETIME_MS = 10 * 60 * 1000
local MAX_BAD_CODES = 5

local function random_code()
    local f = io.open("/dev/urandom", "rb")
    local n
    if f then
        local b = f:read(4)
        f:close()
        n = b:byte(1) * 16777216 + b:byte(2) * 65536 + b:byte(3) * 256 + b:byte(4)
    else
        math.randomseed(os.time()); n = math.random(0, 2 ^ 31)
    end
    return string.format("%06d", n % 1000000)
end

local function html_escape(s)
    return (tostring(s or ""):gsub("[&<>\"']", { ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;" }))
end

local function url_decode(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function parse_form(s)
    local t = {}
    for pair in (s or ""):gmatch("[^&]+") do
        local k, v = pair:match("^([^=]*)=?(.*)$")
        if k then t[url_decode(k)] = url_decode(v or "") end
    end
    return t
end

--- Constant-time string comparison (the code must not leak via timing).
local function same(a, b)
    if type(a) ~= "string" or type(b) ~= "string" or #a ~= #b then return false end
    local diff = 0
    for i = 1, #a do diff = bit.bor(diff, bit.bxor(a:byte(i), b:byte(i))) end
    return diff == 0
end

--- opts: app, providers = { {id, label, needs_url, no_key} }, on_save(fields) -> ok, message,
--        on_event(kind, text)  -- "saved" | "error" | "stopped"
function Server.new(opts)
    return setmetatable({ opts = opts, conns = {}, bad = 0 }, Server)
end

function Server:start()
    if not ok_core or not core.tcp_listen then return nil, "This build of Tome can't run the setup page." end
    local d = self.opts.app.device
    local ip = d.wifi_ip and d:wifi_ip()
    if not ip then return nil, "Wi-Fi isn't connected. Turn on Wi-Fi and try again." end
    local fd, err
    for port = 8765, 8775 do
        fd, err = core.tcp_listen(ip, port)
        if fd then self.port = port; break end
    end
    if not fd then return nil, "Couldn't start the setup page: " .. tostring(err) end
    self.fd, self.ip = fd, ip
    self.code = random_code()
    self.started = d:monotonic_ms()
    d:open_port(self.port)
    self.url = string.format("http://%s:%d/", ip, self.port)
    log.info("setup page listening on", self.url)
    return self.url, self.code
end

--- Link for the QR code: includes the one-time code.
function Server:qr_url()
    return self.url .. "?c=" .. self.code
end

function Server:stop(reason)
    if not self.fd then return end
    for _, c in ipairs(self.conns) do core.close(c.fd) end
    self.conns = {}
    core.close(self.fd)
    self.fd = nil
    self.opts.app.device:close_port(self.port)
    log.info("setup page stopped:", reason or "")
    if self.opts.on_event then self.opts.on_event("stopped", reason) end
end

function Server:running() return self.fd ~= nil end

------------------------------------------------------------------------------
-- Pages
------------------------------------------------------------------------------

local STYLE = [[
body{font:17px/1.45 -apple-system,system-ui,sans-serif;max-width:30em;margin:1.5em auto;padding:0 1em;color:#111}
h1{font-size:1.4em}label{display:block;margin:1em 0 .3em;font-weight:600}
input,select{width:100%;box-sizing:border-box;font-size:1em;padding:.6em;border:1px solid #888;border-radius:6px}
button{margin-top:1.4em;width:100%;padding:.8em;font-size:1.05em;border:0;border-radius:6px;background:#111;color:#fff}
.note{color:#555;font-size:.9em}.ok{color:#060}.err{color:#a00}
]]

local function page(title, body)
    return "<!doctype html><html><head><meta charset=utf-8>"
        .. "<meta name=viewport content='width=device-width,initial-scale=1'>"
        .. "<title>" .. html_escape(title) .. "</title><style>" .. STYLE .. "</style></head><body>"
        .. body .. "</body></html>"
end

function Server:form_page(code, message)
    local opts = {}
    for _, p in ipairs(self.opts.providers) do
        opts[#opts + 1] = string.format("<option value='%s'>%s</option>", html_escape(p.id), html_escape(p.label))
    end
    local code_field = code
        and string.format("<input type=hidden name=c value='%s'>", html_escape(code))
        or "<label>Code shown on your Kindle</label><input name=c inputmode=numeric autocomplete=off required>"
    return page("Tome setup", "<h1>Tome: AI recap setup</h1>"
        .. (message and ("<p class=err>" .. html_escape(message) .. "</p>") or "")
        .. "<form method=post action=/save autocomplete=off>" .. code_field
        .. "<label>Provider</label><select name=provider>" .. table.concat(opts) .. "</select>"
        .. "<label>API key</label><input name=key type=password autocomplete=off spellcheck=false "
        .. "placeholder='Paste your key'>"
        .. "<p class=note>Not needed for Ollama.</p>"
        .. "<label>Model <span class=note>(optional)</span></label>"
        .. "<input name=model placeholder='auto' autocomplete=off spellcheck=false>"
        .. "<label>Server address <span class=note>(Ollama only)</span></label>"
        .. "<input name=url placeholder='http://192.168.1.20:11434/v1' autocomplete=off spellcheck=false>"
        .. "<button type=submit>Save to Kindle</button></form>"
        .. "<p class=note>The key is sent over your Wi-Fi to your Kindle only, and stored there. "
        .. "Use this on your home network.</p>")
end

------------------------------------------------------------------------------
-- HTTP handling
------------------------------------------------------------------------------

local function respond(fd, status, body, extra)
    local headers = {
        "HTTP/1.1 " .. status,
        "Content-Type: text/html; charset=utf-8",
        "Content-Length: " .. #body,
        "Cache-Control: no-store",
        "Referrer-Policy: no-referrer",
        "X-Frame-Options: DENY",
        "X-Content-Type-Options: nosniff",
        "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'",
        "Connection: close",
    }
    for _, h in ipairs(extra or {}) do headers[#headers + 1] = h end
    local data = table.concat(headers, "\r\n") .. "\r\n\r\n" .. body
    local sent, tries = 0, 0
    while sent < #data and tries < 200 do
        local n = core.write(fd, data:sub(sent + 1))
        if not n then break end
        sent = sent + n
        if n == 0 then core.sleep_ms(5); tries = tries + 1 end
    end
end

--- Handle one complete request. Returns true if the server should stop.
function Server:handle_request(fd, req)
    local head, body = req:match("^(.-)\r\n\r\n(.*)$")
    local method, target = (head or ""):match("^(%u+) (%S+) HTTP/1%.[01]")
    if not method then respond(fd, "400 Bad Request", page("Error", "<p>Bad request</p>")); return end
    -- Host must be the Kindle's own address
    local host = head:match("\r\n[Hh]ost:%s*([^\r\n]+)")
    local expected = self.ip .. ":" .. self.port
    if host ~= expected and host ~= self.ip then
        respond(fd, "421 Misdirected Request", page("Error", "<p>Open the address shown on your Kindle.</p>"))
        return
    end
    local path, query = target:match("^([^?]*)%??(.*)$")
    if method == "GET" and path == "/" then
        local q = parse_form(query)
        local code = q.c and same(q.c, self.code) and q.c or nil
        respond(fd, "200 OK", self:form_page(code, (q.c and not code) and "That code doesn't match. Enter the code shown on the Kindle." or nil))
        return
    end
    if method == "POST" and path == "/save" then
        local f = parse_form(body)
        if not same(f.c, self.code) then
            self.bad = self.bad + 1
            if self.bad >= MAX_BAD_CODES then
                respond(fd, "403 Forbidden", page("Locked", "<p class=err>Too many wrong codes. Setup is closed; start it again on the Kindle.</p>"))
                if self.opts.on_event then self.opts.on_event("error", "Too many wrong codes. Setup closed.") end
                return true
            end
            respond(fd, "403 Forbidden", self:form_page(nil, "Wrong code. Check the code on your Kindle."))
            return
        end
        local ok, msg = self.opts.on_save(f)
        if ok then
            respond(fd, "200 OK", page("Saved", "<h1 class=ok>Saved \226\156\147</h1><p>Your key is on your Kindle now. "
                .. "Check the Kindle screen: it is testing the key.</p><p class=note>You can close this page.</p>"))
            return true
        end
        respond(fd, "400 Bad Request", self:form_page(self.code, msg or "Couldn't save."))
        return
    end
    respond(fd, "404 Not Found", page("Not found", "<p>Not found</p>"))
end

--- Call regularly (from a UI task). Accepts and serves connections without blocking.
function Server:step()
    if not self.fd then return end
    local d = self.opts.app.device
    local now = d:monotonic_ms()
    if now - self.started > LIFETIME_MS then self:stop("timeout"); return end
    for _ = 1, 4 do
        local cfd, peer = core.accept(self.fd)
        if not cfd then break end
        self.conns[#self.conns + 1] = { fd = cfd, buf = "", t = now, peer = peer }
    end
    for i = #self.conns, 1, -1 do
        local c = self.conns[i]
        local chunk = core.read(c.fd, 4096)
        if chunk and chunk ~= "" then c.buf = c.buf .. chunk end
        local done, stop = false, false
        if #c.buf > MAX_REQUEST then
            respond(c.fd, "413 Payload Too Large", page("Error", "<p>Too large</p>")); done = true
        elseif now - c.t > CONN_TIMEOUT_MS then
            done = true
        else
            local head_end = c.buf:find("\r\n\r\n", 1, true)
            if head_end then
                local len = tonumber(c.buf:sub(1, head_end):match("\r\n[Cc]ontent%-[Ll]ength:%s*(%d+)") or "0") or 0
                if #c.buf >= head_end + 3 + len then
                    local ok, res = pcall(self.handle_request, self, c.fd, c.buf)
                    if not ok then log.error("setup page error:", res) end
                    done, stop = true, ok and res == true
                end
            end
            if chunk == nil then done = true end -- connection error
        end
        if done then
            core.close(c.fd)
            table.remove(self.conns, i)
        end
        if stop then self:stop("done"); return end
    end
end

return Server
