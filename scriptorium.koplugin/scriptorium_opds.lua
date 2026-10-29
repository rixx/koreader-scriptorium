--[[--
Pull new books from OPDS catalogs, in the background.

Uses the catalogs that have "Sync catalog" ticked in KOReader's OPDS plugin,
with their credentials, sync folder, file types and max-files settings
(settings/opds.lua, read only). Unlike the built-in sync, it walks the whole
feed instead of stopping at a watermark, so feed order does not matter, and
it remembers every book it has pulled: a book you read and deleted is not
pulled again, even while the server still lists it.

Never turns on WiFi, never overwrites or deletes a book. Downloads run in a
subprocess so the UI stays responsive. The ledger lives in
settings/opds_autosync.lua (the name predates the move from a user patch);
delete a "pulled" entry to get that book again.
]]

local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local buffer = require("string.buffer")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiutil.template

local Opds = {}

-- Background pulls after a clean run wait this long; failed runs retry on the next hook.
Opds.MIN_INTERVAL_SECONDS = 30 * 60
local MAX_PAGES = 100
local ACQUISITION_REL = "^http://opds%-spec%.org/acquisition"
local BORROW_REL = "http://opds-spec.org/acquisition/borrow"

local function getFiletype(href, mimetype)
    local DocumentRegistry = require("document/documentregistry")
    local suffix = util.getFileNameSuffix(href)
    if suffix ~= "" and DocumentRegistry:hasProvider("dummy." .. suffix) then
        return suffix:lower()
    end
    if mimetype and DocumentRegistry:hasProvider(nil, mimetype) then
        return DocumentRegistry:mimeToExt(mimetype)
    end
end

-- Same "Author - Title" naming as the OPDS plugin, so manual downloads count as present.
function Opds.entryName(entry)
    local title = type(entry.title) == "string" and entry.title or "Unknown"
    local names = {}
    local authors = type(entry.author) == "table" and entry.author or {}
    -- Parsers before upstream's 2026-10 fix return one author as a table, not a list.
    if authors.name then
        authors = { authors }
    end
    for _, author in ipairs(authors) do
        local name = type(author) == "table" and author.name
        if type(name) == "table" then
            name = table.concat(name, ", ")
        end
        if type(name) == "string" and name ~= "" then
            table.insert(names, name)
        end
    end
    if #names > 0 then
        title = table.concat(names, ", ") .. " - " .. title
    end
    return util.replaceAllInvalidChars(title)
end

-- Turn one parsed OPDS 1.x page into download candidates and the next page's URL.
function Opds.readPage(feed, page_url, filetypes)
    local url = require("socket.url")
    feed = feed.feed or feed
    local books, next_url = {}, nil
    for _, link in ipairs(feed.link or {}) do
        if link.rel == "next" and link.href then
            next_url = url.absolute(page_url, link.href)
        end
    end
    for _, entry in ipairs(feed.entry or {}) do
        for _, link in ipairs(entry.link or {}) do
            if link.href and link.rel and link.rel ~= BORROW_REL and link.rel:match(ACQUISITION_REL) then
                local href = url.absolute(page_url, link.href)
                local ext = getFiletype(href, link.type)
                if ext and (not filetypes or filetypes[ext]) then
                    table.insert(books, {
                        key = type(entry.id) == "string" and entry.id or href,
                        href = href,
                        name = Opds.entryName(entry),
                        ext = ext,
                    })
                    break
                end
            end
        end
    end
    return books, next_url
end

local function request(req, server)
    local http = require("socket.http")
    local socketutil = require("socketutil")
    req.user, req.password = server.username, server.password
    req.headers = { ["Accept-Encoding"] = "identity" }
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code = select(2, http.request(req))
    socketutil:reset_timeout()
    return code
end

local function fetchPage(page_url, server)
    local ltn12 = require("ltn12")
    local OPDSParser = require("opdsparser")
    local sink = {}
    local code = request({ url = page_url, sink = ltn12.sink.table(sink) }, server)
    if code ~= 200 then
        return nil, T("HTTP %1 for %2", tostring(code), page_url)
    end
    local ok, feed = pcall(OPDSParser.parse, OPDSParser, table.concat(sink))
    if not ok or type(feed) ~= "table" then
        return nil, T("unparseable feed %1: %2", page_url, tostring(feed))
    end
    return feed
end

-- Download to a .part file and rename, so an interrupted run leaves no half book behind.
local function download(href, path, server)
    local ltn12 = require("ltn12")
    local part = path .. ".part"
    local fh, err = io.open(part, "wb")
    if not fh then
        return false, err
    end
    local code = request({ url = href, sink = ltn12.sink.file(fh) }, server)
    if code == 200 and (lfs.attributes(part, "size") or 0) > 0 and os.rename(part, path) then
        return true
    end
    os.remove(part)
    return false, T("HTTP %1 for %2", tostring(code), href)
end

-- Runs in the subprocess. Returns the books now on disk (downloaded or found already
-- present) so the parent can record them, plus per-catalog errors.
function Opds.runSync(servers, opds_settings, pulled)
    local result = { pulled = {}, downloaded = 0, errors = {} }
    local max_dl = opds_settings.sync_max_dl or 50
    local filetypes
    if opds_settings.filetypes then
        filetypes = {}
        for ext in util.gsplit(opds_settings.filetypes, ",") do
            filetypes[util.trim(ext):lower()] = true
        end
    end
    for _, server in ipairs(servers) do
        local dir = server.sync_dir or opds_settings.sync_dir
        if not dir or lfs.attributes(dir, "mode") ~= "directory" then
            table.insert(result.errors, T("%1: sync folder %2 missing", server.title, tostring(dir)))
        else
            local page_url, pages, seen_pages = server.url, 0, {}
            while page_url and not seen_pages[page_url] and pages < MAX_PAGES and result.downloaded < max_dl do
                seen_pages[page_url] = true
                pages = pages + 1
                local feed, err = fetchPage(page_url, server)
                if not feed then
                    table.insert(result.errors, T("%1: %2", server.title, err))
                    break
                end
                local books
                books, page_url = Opds.readPage(feed, page_url, filetypes)
                for _, book in ipairs(books) do
                    if result.downloaded >= max_dl then
                        break
                    end
                    if not pulled[book.key] then
                        local path = dir:gsub("/$", "")
                            .. "/"
                            .. util.getSafeFilename(book.name .. "." .. book.ext, dir)
                        local present = lfs.attributes(path, "mode") ~= nil
                        local ok, dl_err = present, nil
                        if not present then
                            ok, dl_err = download(book.href, path, server)
                        end
                        if ok then
                            pulled[book.key] = true -- same book listed twice, e.g. in two catalogs
                            result.pulled[book.key] = { file = path, downloaded = not present }
                            if not present then
                                result.downloaded = result.downloaded + 1
                            end
                        else
                            table.insert(result.errors, T("%1: %2", server.title, dl_err))
                        end
                    end
                end
            end
        end
    end
    return result
end

local state
local running = false

local function getState()
    state = state or LuaSettings:open(DataStorage:getSettingsDir() .. "/opds_autosync.lua")
    return state
end

-- The OPDS plugin's catalogs with "Sync catalog" ticked, and its global settings.
function Opds.syncCatalogs()
    local opds = LuaSettings:open(DataStorage:getSettingsDir() .. "/opds.lua")
    local servers = {}
    for _, server in ipairs(opds:readSetting("servers") or {}) do
        if server.sync and server.url then
            table.insert(servers, server)
        end
    end
    return servers, opds:readSetting("settings") or {}
end

local function notify(text, timeout)
    UIManager:show(InfoMessage:new({ text = text, timeout = timeout }))
end

local function finish(result, interactive)
    running = false
    if not result then
        logger.warn("scriptorium: OPDS pull subprocess returned nothing")
        if interactive then
            notify(_("OPDS pull failed, see the KOReader log."))
        end
        return
    end
    local st = getState()
    local pulled = st:readSetting("pulled", {})
    local now = os.time()
    -- Only a clean run starts the wait; after a failure the next hook tries again.
    if #result.errors == 0 then
        st:saveSetting("last_success", now)
    end
    for key, book in pairs(result.pulled) do
        pulled[key] = { file = book.file, time = now }
        if book.downloaded then
            logger.info("scriptorium: OPDS pulled", book.file)
        end
    end
    st:flush()
    for _, err in ipairs(result.errors) do
        logger.warn("scriptorium: OPDS pull:", err)
    end
    if result.downloaded > 0 then
        notify(T(_("OPDS: %1 new book(s)"), result.downloaded), 3)
        local FileManager = require("apps/filemanager/filemanager")
        if FileManager.instance then
            FileManager.instance:onRefresh()
        end
    elseif interactive then
        notify(#result.errors > 0 and _("OPDS pull failed, see the KOReader log.") or _("OPDS: no new books"), 3)
    end
end

--[[--
Start a pull. interactive: from the menu; reports every outcome and skips the
wait after the last clean run.
]]
function Opds.pull(interactive)
    if running then
        if interactive then
            notify(_("OPDS pull already running."), 3)
        end
        return
    end
    local servers, opds_settings = Opds.syncCatalogs()
    if #servers == 0 then
        if interactive then
            notify(_('No OPDS catalog has "Sync catalog" enabled.'))
        end
        return
    end
    local st = getState()
    if not interactive and os.time() - (st:readSetting("last_success") or 0) < Opds.MIN_INTERVAL_SECONDS then
        return
    end
    if not NetworkMgr:isOnline() then
        if interactive then
            notify(_("OPDS pull: not online."))
        end
        return
    end

    local pulled = {}
    for key in pairs(st:readSetting("pulled", {})) do
        pulled[key] = true
    end
    local pid, read_fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local ok, result = pcall(Opds.runSync, servers, opds_settings, pulled)
        if not ok then
            logger.warn("scriptorium: OPDS pull crashed:", result)
            result = nil
        end
        ffiutil.writeToFD(write_fd, result and buffer.encode(result) or "", true)
    end, true)
    if not pid then
        logger.warn("scriptorium: cannot start OPDS pull subprocess:", read_fd)
        return
    end
    running = true
    logger.info("scriptorium: OPDS pull from", #servers, "catalog(s)")
    if interactive then
        notify(_("OPDS pull started."), 2)
    end

    local function collect()
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(5, collect)
        end
    end
    local function poll()
        local done = ffiutil.isSubProcessDone(pid)
        if ffiutil.getNonBlockingReadSize(read_fd) ~= 0 or done then
            local data = ffiutil.readAllFromFD(read_fd)
            local ok, result = pcall(buffer.decode, data)
            finish(ok and type(result) == "table" and result or nil, interactive)
            if not done then
                UIManager:scheduleIn(1, collect)
            end
            return
        end
        UIManager:scheduleIn(2, poll)
    end
    UIManager:scheduleIn(2, poll)
end

local function backgroundPull()
    Opds.pull(false)
end

-- Resume and NetworkConnected arrive before WiFi is reliably usable; wait a bit.
-- Module-level, so plugin instances (file manager, reader) share one pending pull.
function Opds.schedule()
    UIManager:unschedule(backgroundPull)
    UIManager:scheduleIn(10, backgroundPull)
end

-- Number of books in the ledger, for the menu.
function Opds.pulledCount()
    local n = 0
    for _ in pairs(getState():readSetting("pulled", {})) do
        n = n + 1
    end
    return n
end

return Opds
