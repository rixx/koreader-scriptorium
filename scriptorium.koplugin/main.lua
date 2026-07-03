--[[--
Scriptorium: push finished books — metadata, finished date, reading time,
and all highlights — to a scriptorium instance (books.rixx.de).

Design: SPEC.md in the repo root. The primary mechanism is a debounced scan
for finished-but-unpushed books on lifecycle hooks; there is no
"book finished" event in KOReader (SPEC §5.4).

Safety: the device's reading data is not backed up. This plugin never writes
to sidecars, the statistics database, or any other KOReader state — its own
memory lives in <settings dir>/scriptorium.lua. Closed books are read via
DocSettings.openSettingsFile (a pure read); DocSettings:open is avoided
because it deletes sidecar candidate files it considers invalid.
]]

local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local Api = require("scriptorium_api")
local Collect = require("scriptorium_collect")
local State = require("scriptorium_state")

-- Lifecycle hooks fire in bursts (close→suspend, resume→network-connected);
-- skip the scan if the last attempt was this recent (SPEC §5.4).
local DEBOUNCE_SECONDS = 60

local Scriptorium = WidgetContainer:extend{
    name = "scriptorium",
    is_doc_only = false,
}

function Scriptorium:init()
    self.state = State.open()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Scriptorium:onDispatcherRegisterActions()
    Dispatcher:registerAction("scriptorium_push", {
        category = "none",
        event = "ScriptoriumPush",
        title = _("Scriptorium: push to server"),
        general = true,
    })
end

-- Gesture-assignable: push the open book, or scan everything from the file
-- manager.
function Scriptorium:onScriptoriumPush()
    if self.ui and self.ui.document then
        self:pushCurrentBook()
    else
        self:scanAndPush({ interactive = true })
    end
end

function Scriptorium:isConfigured()
    return self.state:get("server_url") ~= "" and self.state:get("api_key") ~= ""
end

function Scriptorium:notify(text, interactive)
    local timeout
    if not interactive then
        timeout = 5 -- non-blocking for background pushes (SPEC §5.6)
    end
    UIManager:show(InfoMessage:new{
        text = text,
        timeout = timeout,
    })
end

-- ------------------------------------------------------------------ menu --

function Scriptorium:addToMainMenu(menu_items)
    menu_items.scriptorium = {
        text = _("Scriptorium"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Push this book"),
                enabled_func = function()
                    return self.ui ~= nil and self.ui.document ~= nil
                end,
                callback = function()
                    self:pushCurrentBook()
                end,
            },
            {
                text = _("Push all finished books"),
                callback = function()
                    self:scanAndPush({ interactive = true, force = true })
                end,
                separator = true,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text_func = function()
                            return T(_("Server: %1"), self.state:get("server_url"))
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            self:editServerSettings(touchmenu_instance)
                        end,
                        separator = true,
                    },
                    {
                        text = _("Periodic sync"),
                        help_text = _("Scan for finished, not yet pushed books whenever a book is closed or the device suspends, resumes, powers off, or connects to a network. Never turns on WiFi by itself."),
                        checked_func = function()
                            return self.state:get("periodic_sync")
                        end,
                        callback = function()
                            self.state:toggle("periodic_sync")
                            self.state:flush()
                        end,
                    },
                    {
                        text = _("Push as soon as a book is finished"),
                        help_text = _("Try to push right when a book is marked as finished, instead of waiting for the next periodic scan."),
                        checked_func = function()
                            return self.state:get("push_on_finish")
                        end,
                        callback = function()
                            self.state:toggle("push_on_finish")
                            self.state:flush()
                        end,
                    },
                    {
                        text = _("Also push abandoned books"),
                        help_text = _("Push books marked 'On hold' as did-not-finish reads."),
                        checked_func = function()
                            return self.state:get("push_abandoned")
                        end,
                        callback = function()
                            self.state:toggle("push_abandoned")
                            self.state:flush()
                        end,
                    },
                },
            },
            {
                text = _("About"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_("Scriptorium plugin %1\n\nServer: %2\nBooks pushed so far: %3\n\nPushes finished books with their highlights to scriptorium."),
                            Api.VERSION, self.state:get("server_url"), self.state:pushedCount()),
                    })
                end,
            },
        },
    }
end

function Scriptorium:editServerSettings(touchmenu_instance)
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Scriptorium server"),
        fields = {
            {
                text = self.state:get("server_url"),
                hint = _("Server URL (https://…)"),
            },
            {
                text = self.state:get("api_key"),
                hint = _("API token"),
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = dialog:getFields()
                        local server_url = util.trim(fields[1] or ""):gsub("/+$", "")
                        local api_key = util.trim(fields[2] or "")
                        self.state:set("server_url", server_url)
                        self.state:set("api_key", api_key)
                        self.state:flush()
                        UIManager:close(dialog)
                        if touchmenu_instance then
                            touchmenu_instance:updateItems()
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

-- ---------------------------------------------------------------- pushes --

-- Manual/instant push of the live book, regardless of status (force-push:
-- bypasses the pushed-state check; the server decides what it accepts).
function Scriptorium:pushCurrentBook(auto)
    local interactive = not auto
    if not self:isConfigured() then
        if interactive then
            self:notify(_("Scriptorium is not configured yet — set the server URL and API token in the settings."), true)
        end
        return
    end
    if not (self.ui and self.ui.document and self.ui.doc_settings) then
        if interactive then
            self:notify(_("No book is open."), true)
        end
        return
    end
    -- Flush in-memory reading statistics so the DB query sees this session
    -- (additive write by the statistics plugin's own API; SPEC §2.2).
    if self.ui.statistics then
        pcall(function() self.ui.statistics:insertDB() end)
    end
    -- Live annotations: the sidecar on disk may be stale until close.
    local annotations = self.ui.annotation and self.ui.annotation.annotations
    local book, fp_or_err = Collect.bookPayload(self.ui.doc_settings, annotations)
    if not book then
        self:notify(T(_("Scriptorium: cannot push this book: %1"), fp_or_err), interactive)
        return
    end
    local jobs = { { book = book, fingerprint = fp_or_err } }
    NetworkMgr:runWhenOnline(function()
        self:doPush(jobs, interactive)
    end)
end

local ACTION_TEXT = {
    matched = _("matched existing book"),
    created_book = _("created new book (review queue)"),
    updated_read = _("updated existing read"),
    error = _("error"),
}

-- Books per request: keeps each POST well below typical reverse-proxy body
-- size limits (nginx defaults to 1 MB) even with highlight-heavy books.
local PUSH_CHUNK_SIZE = 5

-- Send jobs in chunks and record what the server accepted. jobs is a list of
-- { book = payload, fingerprint = string, path = ?, mtime = ? }; path/mtime
-- are set for scan jobs so the scan cache can be updated on success.
--
-- A 413 (payload too large) splits the offending chunk in half and retries,
-- down to single books, so one fat backlog push can't fail wholesale. Any
-- other failure aborts: unsent books stay out of the pushed table and the
-- next scan retries them (SPEC §5.6).
function Scriptorium:doPush(jobs, interactive)
    local server_url = self.state:get("server_url")
    local api_key = self.state:get("api_key")

    local queue = {}
    for i = 1, #jobs, PUSH_CHUNK_SIZE do
        local chunk = {}
        for j = i, math.min(i + PUSH_CHUNK_SIZE - 1, #jobs) do
            table.insert(chunk, jobs[j])
        end
        table.insert(queue, chunk)
    end

    local results = {}
    local fatal_err
    while #queue > 0 do
        local chunk = table.remove(queue, 1)
        local books = {}
        for _, job in ipairs(chunk) do
            table.insert(books, job.book)
        end
        local chunk_results, err, code = Api.sync(server_url, api_key, books)
        if chunk_results then
            for _, result in ipairs(chunk_results) do
                table.insert(results, result)
            end
        elseif code == 413 and #chunk > 1 then
            logger.info("scriptorium: payload too large, splitting chunk of", #chunk)
            local mid = math.floor(#chunk / 2)
            local head, tail = {}, {}
            for idx, job in ipairs(chunk) do
                table.insert(idx <= mid and head or tail, job)
            end
            table.insert(queue, 1, tail)
            table.insert(queue, 1, head)
        elseif code == 413 then
            table.insert(results, {
                md5 = chunk[1].book.md5,
                action = "error",
                detail = _("book too large for the server's request size limit"),
            })
        else
            fatal_err = err
            break
        end
    end

    if #results == 0 then
        self:notify(T(_("Scriptorium: push failed: %1"), fatal_err or _("unknown error")), interactive)
        return
    end

    local jobs_by_md5 = {}
    for _, job in ipairs(jobs) do
        jobs_by_md5[job.book.md5] = job
    end

    local lines = {}
    local errors = 0
    for _, result in ipairs(results) do
        local job = jobs_by_md5[result.md5]
        local title = job and job.book.title or tostring(result.md5)
        local line = T("%1: %2", title, ACTION_TEXT[result.action] or tostring(result.action))
        if result.action == "error" then
            errors = errors + 1
            if result.detail then
                line = line .. " — " .. result.detail
            end
        elseif job then
            self.state:recordPushed(job.book.md5, job.book.finished_on, job.fingerprint)
            if job.path and job.mtime then
                self.state:setScanCache(job.path, job.mtime)
            end
        end
        if result.warnings and #result.warnings > 0 then
            line = line .. "\n  " .. table.concat(result.warnings, "\n  ")
        end
        table.insert(lines, line)
    end
    self.state:flush()

    local header
    if errors == 0 then
        header = T(_("Scriptorium: pushed %1 book(s)"), #results)
    else
        header = T(_("Scriptorium: %1 of %2 book(s) failed"), errors, #results)
    end
    if fatal_err then
        header = header .. "\n" .. T(_("Push aborted early (%1) — remaining books will be retried on the next scan."), fatal_err)
    end
    self:notify(header .. "\n\n" .. table.concat(lines, "\n"), interactive)
end

-- ------------------------------------------------------------------ scan --

-- The periodic scan (SPEC §5.4): iterate reading history, skip unchanged
-- sidecars via mtime cache, and push any finished book the pushed-state
-- table doesn't cover — including re-pushes when the finish date or the
-- highlight fingerprint changed (SPEC §5.5).
function Scriptorium:scanAndPush(opts)
    opts = opts or {}
    if not self:isConfigured() then
        if opts.interactive then
            self:notify(_("Scriptorium is not configured yet — set the server URL and API token in the settings."), true)
        end
        return
    end
    local ReadHistory = require("readhistory")
    local scan_cache = self.state:scanCache()
    local pushed = self.state:pushed()
    local push_abandoned = self.state:get("push_abandoned")
    local live_path = self.ui and self.ui.document and self.ui.document.file

    if self.ui and self.ui.statistics then
        pcall(function() self.ui.statistics:insertDB() end)
    end

    local jobs = {}
    local seen_md5 = {}
    for _, entry in ipairs(ReadHistory.hist or {}) do
        local path = entry.file
        if path and not entry.dim then
            local job = self:examineBook(path, live_path == path, opts.force,
                scan_cache, pushed, push_abandoned, seen_md5)
            if job then
                table.insert(jobs, job)
            end
        end
    end
    self.state:flush()

    if #jobs == 0 then
        if opts.interactive then
            self:notify(_("Scriptorium: nothing to push — all finished books are already on the server."), true)
        end
        return
    end
    logger.info("scriptorium: found", #jobs, "book(s) to push")

    if opts.interactive then
        NetworkMgr:runWhenOnline(function()
            self:doPush(jobs, true)
        end)
    elseif NetworkMgr:isOnline() then
        self:doPush(jobs, false)
    else
        -- Never touch WiFi from a background scan; the books stay pending
        -- and onNetworkConnected retries (SPEC §5.4).
        logger.dbg("scriptorium: offline, deferring push of", #jobs, "book(s)")
    end
end

-- Check one history entry; returns a push job or nil. Updates the scan cache
-- for books that need no push, so the next scan skips them on one
-- lfs.attributes call. Pending books deliberately keep a stale cache entry —
-- that is the retry mechanism.
function Scriptorium:examineBook(path, is_live, force, scan_cache, pushed, push_abandoned, seen_md5)
    local sidecar = DocSettings:findSidecarFile(path)
    if not sidecar then
        return nil -- never opened or sidecar stranded; nothing to read
    end
    local mtime = lfs.attributes(sidecar, "modification")
    if not force and not is_live and scan_cache[path] == mtime then
        return nil
    end

    local ds, annotations
    if is_live then
        -- Freshest source, and the on-disk sidecar may be stale; annotations
        -- live in the annotation module until close.
        ds = self.ui.doc_settings
        annotations = self.ui.annotation and self.ui.annotation.annotations
    else
        -- Pure read. Never DocSettings:open() here: it deletes sidecar
        -- candidate files it considers invalid, and device data has no backup.
        ds = DocSettings.openSettingsFile(sidecar)
    end

    -- The live book's disk state may lag; only cache-skip closed books.
    local function done()
        if not is_live then
            self.state:setScanCache(path, mtime)
        end
        return nil
    end

    local summary = ds:readSetting("summary") or {}
    local eligible = summary.status == "complete"
        or (push_abandoned and summary.status == "abandoned")
    if not eligible then
        return done()
    end

    local book, fp_or_err = Collect.bookPayload(ds, annotations)
    if not book then
        logger.info("scriptorium: skipping", path, "—", fp_or_err)
        return done()
    end
    if seen_md5[book.md5] then
        return done() -- duplicate history entry for the same content
    end
    seen_md5[book.md5] = true

    local record = pushed[book.md5]
    if record and record.modified == book.finished_on
            and record.fingerprint == fp_or_err then
        return done() -- server already has this read with these highlights
    end

    return {
        book = book,
        fingerprint = fp_or_err,
        path = not is_live and path or nil,
        mtime = not is_live and mtime or nil,
    }
end

-- ----------------------------------------------------- lifecycle triggers --

function Scriptorium:maybeScan()
    if not self.state:get("periodic_sync") then return end
    if not self:isConfigured() then return end
    local now = os.time()
    if now - (self.state:get("last_attempt") or 0) < DEBOUNCE_SECONDS then
        return
    end
    self.state:set("last_attempt", now)
    self.state:flush()
    self:scanAndPush({ interactive = false })
end

Scriptorium.onCloseDocument = Scriptorium.maybeScan
Scriptorium.onSuspend = Scriptorium.maybeScan
Scriptorium.onPowerOff = Scriptorium.maybeScan
Scriptorium.onReboot = Scriptorium.maybeScan
Scriptorium.onResume = Scriptorium.maybeScan
Scriptorium.onNetworkConnected = Scriptorium.maybeScan

function Scriptorium:onFlushSettings()
    self.state:flush()
end

-- Optional instant push-on-finish (SPEC §5.4.3): there is no status-change
-- event, so snapshot the status when the book opens and re-check after
-- onEndOfBook, one UI tick later so the mark-as-finished dialog has resolved.
-- Anything this misses is caught by the next periodic scan.
function Scriptorium:onReaderReady()
    if self.ui and self.ui.doc_settings then
        local summary = self.ui.doc_settings:readSetting("summary")
        self.status_snapshot = summary and summary.status
    end
end

function Scriptorium:onEndOfBook()
    if not self.state:get("push_on_finish") then return end
    if not self:isConfigured() then return end
    UIManager:nextTick(function()
        if not (self.ui and self.ui.doc_settings) then return end
        local summary = self.ui.doc_settings:readSetting("summary") or {}
        if summary.status == "complete" and self.status_snapshot ~= "complete" then
            self.status_snapshot = "complete"
            logger.info("scriptorium: book marked finished, pushing")
            self:pushCurrentBook(true)
        end
    end)
end

return Scriptorium
