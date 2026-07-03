-- Integration smoke test for main.lua: scan, push, idempotency, debounce.
-- Stubs the entire KOReader environment and the HTTP layer.

local SIDECARS = {}   -- path -> data table
local MTIMES = {}     -- sidecar path -> mtime
local HTTP_CALLS = {} -- captured request payloads (as Lua tables)
local HTTP_RESPONSE   -- canned decoded response (used when HTTP_HANDLER is nil)
local HTTP_HANDLER    -- optional function(payload) -> code, decoded response
local CURRENT_RESPONSE
local SHOWN = {}      -- InfoMessages shown
local HIST            -- reading history entries, set below

local now = os.time()

-- ---- stubs ----
package.preload["gettext"] = function() return function(s) return s end end
package.preload["logger"] = function()
    return { warn = function() end, info = function() end, dbg = function() end, err = function() end }
end
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/nonexistent-settings-dir" end }
end
package.preload["lua-ljsqlite3/init"] = function()
    return { open = function() error("no db in test") end }
end
package.preload["libs/libkoreader-lfs"] = function()
    return { attributes = function(path, what)
        if what == "modification" then return MTIMES[path] end
        return nil
    end }
end
package.preload["rapidjson"] = function()
    return {
        array = function(t) return t end,
        encode = function(t) return t end, -- pass tables through; http stub captures them
        decode = function(body) return CURRENT_RESPONSE end,
    }
end
package.preload["device"] = function() return { model = "TestDevice" } end
package.preload["dispatcher"] = function()
    return { registerAction = function() return true end }
end
package.preload["docsettings"] = function()
    return {
        findSidecarFile = function(self, path)
            local sidecar = path .. ".sdr/metadata.epub.lua"
            if SIDECARS[path] then return sidecar end
            return nil
        end,
        openSettingsFile = function(sidecar)
            local path = sidecar:gsub("%.sdr/metadata%.epub%.lua$", "")
            local data = assert(SIDECARS[path], "no sidecar fixture for " .. path)
            return { readSetting = function(_, key) return data[key] end }
        end,
        open = function() error("DocSettings:open must never be called (destructive)") end,
    }
end
package.preload["ui/widget/infomessage"] = function()
    return { new = function(self, o) table.insert(SHOWN, o.text) return o end }
end
package.preload["ui/widget/multiinputdialog"] = function()
    return { new = function(self, o) return o end }
end
package.preload["ui/network/manager"] = function()
    return {
        isOnline = function() return true end,
        runWhenOnline = function(self, cb) cb() end,
    }
end
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        close = function() end,
        nextTick = function(self, cb) cb() end,
    }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local W = {}
    function W:extend(t)
        t = t or {}
        t.__index = t
        return setmetatable(t, { __index = self })
    end
    return W
end
package.preload["util"] = function()
    return { trim = function(s) return s:match("^%s*(.-)%s*$") end }
end
package.preload["ffi/util"] = function()
    return { template = function(str, ...)
        local args = { ... }
        return (str:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
    end }
end
package.preload["socket"] = function()
    return { skip = function(n, ...) return select(n + 1, ...) end }
end
package.preload["socket.http"] = function()
    return { request = function(req)
        table.insert(HTTP_CALLS, req)
        local code
        if HTTP_HANDLER then
            code, CURRENT_RESPONSE = HTTP_HANDLER(req.source)
        else
            code, CURRENT_RESPONSE = 200, HTTP_RESPONSE
        end
        return 1, code, { "content-type: json" }, tostring(code)
    end }
end
package.preload["ltn12"] = function()
    return {
        source = { string = function(s) return s end },
        sink = { table = function(t) return t end },
    }
end
package.preload["socketutil"] = function()
    return {
        LARGE_BLOCK_TIMEOUT = 10, LARGE_TOTAL_TIMEOUT = 30,
        set_timeout = function() end, reset_timeout = function() end,
    }
end
HIST = {
    { file = "/books/finished.epub" },
    { file = "/books/inprogress.epub" },
    { file = "/books/alreadypushed.epub" },
    { file = "/books/abandoned.epub" },
    { file = "/books/deleted.epub", dim = true },
    { file = "/books/legacy.epub" },
}
package.preload["readhistory"] = function()
    return { hist = HIST }
end
-- In-memory LuaSettings
package.preload["luasettings"] = function()
    local store = {}
    local LS = {}
    LS.__index = LS
    function LS:open(path)
        store[path] = store[path] or { data = {} }
        return setmetatable({ data = store[path].data }, LS)
    end
    function LS:readSetting(key, default)
        if self.data[key] == nil and default ~= nil then self.data[key] = default end
        return self.data[key]
    end
    function LS:saveSetting(key, value) self.data[key] = value end
    function LS:flush() end
    return LS
end

G_reader_settings = { readSetting = function(_, key)
    if key == "device_id" then return "test-device-uuid" end
end }

-- rapidjson.encode passes the table through; #body in api.lua needs a length.
-- Give tables a length via __len? Simpler: api.lua does #body on the encoded
-- value — a table. Lua # on a table works (array part), returns 0. Fine.

-- ---- fixtures ----
local function sidecar(status, modified, n_highlights, md5)
    local annotations = {}
    for i = 1, n_highlights do
        annotations[i] = { drawer = "lighten", text = "hl " .. i,
            datetime = ("2026-06-%02d 10:00:00"):format(i), pageno = i * 10 }
    end
    return {
        partial_md5_checksum = md5,
        annotations = annotations,
        summary = { status = status, modified = modified },
        doc_props = { title = md5 .. "-title", authors = "Author" },
        doc_pages = 100,
    }
end

SIDECARS["/books/finished.epub"] = sidecar("complete", "2026-07-01", 3, ("a"):rep(32))
SIDECARS["/books/inprogress.epub"] = sidecar("reading", nil, 1, ("b"):rep(32))
SIDECARS["/books/alreadypushed.epub"] = sidecar("complete", "2026-06-15", 2, ("c"):rep(32))
SIDECARS["/books/abandoned.epub"] = sidecar("abandoned", "2026-06-20", 1, ("d"):rep(32))
SIDECARS["/books/legacy.epub"] = {
    partial_md5_checksum = ("e"):rep(32),
    summary = { status = "complete", modified = "2020-01-01" },
    doc_props = { title = "old book" },
}
for path in pairs(SIDECARS) do
    MTIMES[path .. ".sdr/metadata.epub.lua"] = 1000
end

package.path = "scriptorium.koplugin/?.lua;" .. package.path
local Scriptorium = require("main")

local failures = 0
local function check(cond, msg)
    if cond then print("PASS " .. msg)
    else failures = failures + 1 print("FAIL " .. msg) end
end

-- Build plugin instance (file-manager context: no document open)
local plugin = setmetatable({ ui = { menu = { registerToMainMenu = function() end } } }, Scriptorium)
plugin:init()
plugin.state:set("api_key", "test-token")
plugin.state:recordPushed(("c"):rep(32), "2026-06-15", "2:2026-06-02 10:00:00") -- alreadypushed covered

-- 1. Interactive full scan: only "finished" needs pushing
HTTP_RESPONSE = { results = { { md5 = ("a"):rep(32), action = "created_book", read_id = 1,
    highlights_stored = 3, warnings = { "no ISBN found" } } } }
plugin:scanAndPush({ interactive = true, force = true })
check(#HTTP_CALLS == 1, "one batch pushed")
local req = HTTP_CALLS[1]
check(req.headers["Authorization"] == "Bearer test-token", "bearer auth header")
check(req.url == "https://books.rixx.de/api/koreader/sync", "sync URL")
local payload = req.source
check(payload.plugin_version == require("scriptorium_api").VERSION, "plugin_version in payload")
local meta = dofile("scriptorium.koplugin/_meta.lua")
check(meta.version == require("scriptorium_api").VERSION, "_meta.lua version matches Api.VERSION")
check(payload.device.id == "test-device-uuid" and payload.device.model == "TestDevice", "device info")
check(#payload.books == 1 and payload.books[1].md5 == ("a"):rep(32), "only the unpushed finished book sent")
check(#payload.books[1].highlights == 3, "highlights included")
check(plugin.state:pushed()[("a"):rep(32)] ~= nil, "pushed state recorded")
check(plugin.state:pushed()[("a"):rep(32)].modified == "2026-07-01", "pushed modified date recorded")
check(plugin.state:scanCache()["/books/finished.epub"] == 1000, "scan cache set after success")
check(plugin.state:scanCache()["/books/inprogress.epub"] == 1000, "non-eligible book cached")
check(plugin.state:scanCache()["/books/legacy.epub"] == 1000, "legacy sidecar cached and skipped")

-- 2. Re-scan: nothing to push, no HTTP call
plugin:scanAndPush({ interactive = true, force = true })
check(#HTTP_CALLS == 1, "idempotent: second scan pushes nothing")

-- 3. Highlight edited on the pushed book -> fingerprint change -> re-push
table.insert(SIDECARS["/books/finished.epub"].annotations,
    { drawer = "lighten", text = "new", datetime = "2026-07-02 09:00:00", pageno = 99 })
MTIMES["/books/finished.epub.sdr/metadata.epub.lua"] = 2000
HTTP_RESPONSE = { results = { { md5 = ("a"):rep(32), action = "updated_read", read_id = 1,
    highlights_stored = 4 } } }
plugin:scanAndPush({ interactive = false }) -- non-forced background scan, mtime changed
check(#HTTP_CALLS == 2, "changed fingerprint triggers re-push via mtime cache miss")
check(HTTP_CALLS[2].source.books[1].md5 == ("a"):rep(32), "re-pushed the edited book")

-- 4. Background scan with unchanged mtimes does nothing
plugin:scanAndPush({ interactive = false })
check(#HTTP_CALLS == 2, "mtime cache prevents rescan work")

-- 5. push_abandoned enables DNF push
plugin.state:set("push_abandoned", true)
HTTP_RESPONSE = { results = { { md5 = ("d"):rep(32), action = "created_book", read_id = 2,
    highlights_stored = 1 } } }
plugin:scanAndPush({ interactive = true, force = true })
check(#HTTP_CALLS == 3 and HTTP_CALLS[3].source.books[1].md5 == ("d"):rep(32), "abandoned book pushed when enabled")
check(HTTP_CALLS[3].source.books[1].status == "abandoned", "abandoned status sent")

-- 6. Failed push keeps the book pending (server per-book error)
SIDECARS["/books/finished.epub"].summary.modified = "2026-07-03" -- reread
MTIMES["/books/finished.epub.sdr/metadata.epub.lua"] = 3000
HTTP_RESPONSE = { results = { { md5 = ("a"):rep(32), action = "error", warnings = { "boom" } } } }
plugin:scanAndPush({ interactive = false })
check(#HTTP_CALLS == 4, "reread (new modified date) triggers push")
check(plugin.state:pushed()[("a"):rep(32)].modified == "2026-07-01", "error result does not update pushed state")
HTTP_RESPONSE = { results = { { md5 = ("a"):rep(32), action = "matched", read_id = 3, highlights_stored = 4 } } }
plugin:scanAndPush({ interactive = false })
check(#HTTP_CALLS == 5, "failed book retried on next scan")
check(plugin.state:pushed()[("a"):rep(32)].modified == "2026-07-03", "success updates pushed state")

-- 7. Debounce: maybeScan twice in a row -> one scan
SIDECARS["/books/finished.epub"].summary.modified = "2026-07-04"
MTIMES["/books/finished.epub.sdr/metadata.epub.lua"] = 4000
HTTP_RESPONSE = { results = { { md5 = ("a"):rep(32), action = "matched", read_id = 4, highlights_stored = 4 } } }
plugin:maybeScan()
plugin:maybeScan()
check(#HTTP_CALLS == 6, "debounce: two immediate maybeScan calls push once")

-- 8. periodic_sync off -> maybeScan is a no-op
plugin.state:set("periodic_sync", false)
plugin.state:set("last_attempt", 0)
SIDECARS["/books/finished.epub"].summary.modified = "2026-07-05"
MTIMES["/books/finished.epub.sdr/metadata.epub.lua"] = 5000
plugin:maybeScan()
check(#HTTP_CALLS == 6, "periodic_sync off disables background scans")

-- ---- chunking and 413 handling ----

local function addFinishedBook(name, md5)
    local path = "/books/" .. name .. ".epub"
    SIDECARS[path] = sidecar("complete", "2026-07-01", 1, md5)
    MTIMES[path .. ".sdr/metadata.epub.lua"] = 1000
    table.insert(HIST, { file = path })
    return path
end

local function okHandler(payload)
    local results = {}
    for _, b in ipairs(payload.books) do
        table.insert(results, { md5 = b.md5, action = "matched", read_id = 1,
            highlights_stored = #b.highlights })
    end
    return 200, { results = results }
end

-- 9. Large backlogs are pushed in chunks of 5
for i = 1, 12 do
    addFinishedBook("bulk" .. i, string.format("%02x", 16 + i):rep(16))
end
HTTP_HANDLER = okHandler
local calls_before = #HTTP_CALLS
plugin:scanAndPush({ interactive = true, force = true })
-- 12 bulk books + the still-pending finished.epub from test 8 = 13 jobs
check(#HTTP_CALLS == calls_before + 3, "13 jobs pushed as 3 chunks (5+5+3)")
local max_chunk = 0
for i = calls_before + 1, #HTTP_CALLS do
    max_chunk = math.max(max_chunk, #HTTP_CALLS[i].source.books)
end
check(max_chunk == 5, "no chunk exceeds 5 books")
check(plugin.state:pushed()[string.format("%02x", 17):rep(16)] ~= nil, "chunked books recorded as pushed")
check(plugin.state:pushed()[string.format("%02x", 28):rep(16)] ~= nil, "last chunk recorded as pushed")

-- 10. 413 splits the chunk down to single books
for i = 1, 3 do
    addFinishedBook("fat" .. i, string.format("%02x", 48 + i):rep(16))
end
HTTP_HANDLER = function(payload)
    if #payload.books > 1 then return 413, nil end
    return okHandler(payload)
end
calls_before = #HTTP_CALLS
plugin:scanAndPush({ interactive = true })
-- [3] -> 413 -> [2]+[1]; [2] -> 413 -> [1]+[1]: 2 rejected + 3 single pushes
check(#HTTP_CALLS == calls_before + 5, "413 splits chunk down to single books")
check(plugin.state:pushed()[string.format("%02x", 49):rep(16)] ~= nil, "split books recorded as pushed")
check(plugin.state:pushed()[string.format("%02x", 51):rep(16)] ~= nil, "all split books recorded")

-- 11. A single book that still 413s becomes a per-book error, not a retry loop
local whale_md5 = ("9"):rep(32)
addFinishedBook("whale", whale_md5)
HTTP_HANDLER = function() return 413, nil end
calls_before = #HTTP_CALLS
plugin:scanAndPush({ interactive = true })
check(#HTTP_CALLS == calls_before + 1, "oversized single book fails once, no retry loop")
check(plugin.state:pushed()[whale_md5] == nil, "oversized book not recorded as pushed")
check(SHOWN[#SHOWN]:match("too large") ~= nil, "message names the size problem")

-- 12. Mid-push failure: first chunk lands, the rest stays pending and retries
SIDECARS["/books/whale.epub"] = nil -- drop the hopeless fixture
HIST[#HIST] = { file = "/books/whale.epub", dim = true }
for i = 1, 6 do
    addFinishedBook("late" .. i, string.format("%02x", 64 + i):rep(16))
end
local call_n = 0
HTTP_HANDLER = function(payload)
    call_n = call_n + 1
    if call_n == 1 then return okHandler(payload) end
    return 500, nil
end
plugin:scanAndPush({ interactive = true })
check(plugin.state:pushed()[string.format("%02x", 65):rep(16)] ~= nil, "first chunk recorded despite later failure")
check(plugin.state:pushed()[string.format("%02x", 70):rep(16)] == nil, "unsent book not recorded")
check(SHOWN[#SHOWN]:match("retried on the next scan") ~= nil, "partial failure explained to user")
HTTP_HANDLER = okHandler
calls_before = #HTTP_CALLS
plugin:scanAndPush({ interactive = false })
check(#HTTP_CALLS == calls_before + 1, "leftover book retried on next scan")
check(plugin.state:pushed()[string.format("%02x", 70):rep(16)] ~= nil, "leftover book pushed on retry")

print(failures == 0 and "ALL PASS" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
