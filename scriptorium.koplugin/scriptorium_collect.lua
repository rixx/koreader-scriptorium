--[[--
Build the push payload for one book, from its sidecar data plus the
statistics database (SPEC §5.3).

Everything here is strictly read-only towards KOReader's data: sidecars are
handed in as already-opened DocSettings-like objects, and statistics.sqlite3
is opened with the "ro" flag. The device data is not backed up — this module
must never write.
]]

local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local rapidjson = require("rapidjson")

local Collect = {}

local STATS_DB = DataStorage:getSettingsDir() .. "/statistics.sqlite3"

-- doc_props.authors / identifiers / keywords are newline-separated strings.
local function splitLines(str)
    if type(str) ~= "string" or str == "" then return nil end
    local out = {}
    for line in str:gmatch("[^\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then
            table.insert(out, line)
        end
    end
    if #out == 0 then return nil end
    return out
end

-- Keep only real highlights (drawer == nil means plain page bookmark) and
-- strip engine-specific position internals (pos0/pos1/page xpointers).
function Collect.cleanHighlights(annotations)
    local highlights = {}
    for _, a in ipairs(annotations) do
        if a.drawer then
            table.insert(highlights, {
                text = a.text or "", -- required by the server schema
                note = a.note,
                chapter = a.chapter,
                datetime = a.datetime,
                pageno = a.pageno,
                color = a.color,
                drawer = a.drawer,
            })
        end
    end
    return rapidjson.array(highlights)
end

-- Cheap change detector for the highlight set: count + latest timestamp
-- (datetime or datetime_updated, whichever is newest). A changed fingerprint
-- triggers a re-push so post-finish highlight cleanup reaches the server
-- (SPEC §5.5).
function Collect.fingerprint(annotations)
    local count = 0
    local latest = ""
    for _, a in ipairs(annotations) do
        if a.drawer then
            count = count + 1
            if type(a.datetime) == "string" and a.datetime > latest then
                latest = a.datetime
            end
            if type(a.datetime_updated) == "string" and a.datetime_updated > latest then
                latest = a.datetime_updated
            end
        end
    end
    return count .. ":" .. latest
end

-- Aggregates from statistics.sqlite3: total reading time and the date of the
-- first recorded session. Both optional — the statistics plugin may be
-- disabled or the book unknown to it. Opened read-only.
function Collect.readStats(md5)
    if type(md5) ~= "string" or not md5:match("^%x+$") then
        return nil, nil
    end
    if lfs.attributes(STATS_DB, "mode") ~= "file" then
        return nil, nil
    end
    local started_on, total_time
    local ok, err = pcall(function()
        local conn = SQ3.open(STATS_DB, "ro")
        local read_ok, read_err = pcall(function()
            local total = conn:rowexec(
                ("SELECT SUM(total_read_time) FROM book WHERE md5 = '%s'"):format(md5))
            local first = conn:rowexec(
                ("SELECT MIN(start_time) FROM page_stat_data WHERE id_book IN (SELECT id FROM book WHERE md5 = '%s')"):format(md5))
            if total then
                total_time = tonumber(total)
            end
            if first then
                started_on = os.date("%Y-%m-%d", tonumber(first))
            end
        end)
        conn:close()
        if not read_ok then error(read_err) end
    end)
    if not ok then
        logger.warn("scriptorium: statistics read failed:", err)
        return nil, nil
    end
    return started_on, total_time
end

--[[--
Build the payload for one book (API contract, SPEC §6).

@param ds an object with a readSetting method holding sidecar data: the live
          ui.doc_settings, or a read-only DocSettings.openSettingsFile result.
@param annotations optional override for the annotations table — pass the
          live ui.annotation.annotations in-reader, where the sidecar copy
          may be stale.
@return book payload table + fingerprint, or nil + reason string.
]]
function Collect.bookPayload(ds, annotations)
    -- The server schema requires exactly 32 hex chars; anything else would
    -- fail batch-level validation and poison the whole push.
    local md5 = ds:readSetting("partial_md5_checksum")
    if type(md5) ~= "string" or not md5:match("^%x+$") or #md5 ~= 32 then
        return nil, "sidecar has no valid partial_md5_checksum"
    end
    annotations = annotations or ds:readSetting("annotations")
    if type(annotations) ~= "table" then
        -- pre-v2024.07 sidecar; migrates automatically when the book is
        -- reopened once. No legacy parser by design (SPEC §1.5).
        return nil, "no annotations table (legacy pre-2024.07 sidecar)"
    end
    local summary = ds:readSetting("summary") or {}
    -- The server only accepts finished ("complete") or did-not-finish
    -- ("abandoned") reads, and requires the finish date. Anything else would
    -- fail batch-level schema validation and block every other book in the
    -- same push, so refuse client-side with a usable message.
    if summary.status ~= "complete" and summary.status ~= "abandoned" then
        return nil, "book is not marked as finished"
    end
    if type(summary.modified) ~= "string" or summary.modified == "" then
        return nil, "no finish date (summary.modified) in sidecar"
    end
    local props = ds:readSetting("doc_props") or {}

    local title = props.title
    if type(title) ~= "string" or title == "" then
        local path = ds:readSetting("doc_path")
        title = path and path:gsub(".*/", ""):gsub("%.%w+$", "") or "Unknown"
    end

    local started_on, total_time = Collect.readStats(md5)

    local book = {
        md5 = md5,
        title = title,
        authors = rapidjson.array(splitLines(props.authors) or {}),
        language = props.language,
        series = props.series,
        series_index = tonumber(props.series_index),
        identifiers = rapidjson.array(splitLines(props.identifiers) or {}),
        pages = tonumber(ds:readSetting("doc_pages")),
        status = summary.status,
        rating = (type(summary.rating) == "number" and summary.rating > 0)
            and summary.rating or nil,
        summary_note = (type(summary.note) == "string" and summary.note ~= "")
            and summary.note or nil,
        finished_on = summary.modified,
        started_on = started_on,
        total_time_seconds = total_time,
        highlights = Collect.cleanHighlights(annotations),
    }
    return book, Collect.fingerprint(annotations)
end

return Collect
