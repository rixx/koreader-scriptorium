-- Integration smoke test for main.lua: scan, push, idempotency, debounce.
-- Stubs the entire KOReader environment and the HTTP layer.

local SIDECARS = {}   -- path -> data table
local MTIMES = {}     -- sidecar path -> mtime
local HTTP_CALLS = {} -- captured request payloads (as Lua tables)
local HTTP_RESPONSE   -- canned decoded response
local SHOWN = {}      -- InfoMessages shown

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
        decode = function(body) return HTTP_RESPONSE end,
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
        return 1, 200, { "content-type: json" }, "200 OK"
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
package.preload["readhistory"] = function()
    return { hist = {
        { file = "/books/finished.epub" },
        { file = "/books/inprogress.epub" },
        { file = "/books/alreadypushed.epub" },
        { file = "/books/abandoned.epub" },
        { file = "/books/deleted.epub", dim = true },
        { file = "/books/legacy.epub" },
    } }
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
check(payload.plugin_version == "1.0.0", "plugin_version in payload")
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

print(failures == 0 and "ALL PASS" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
