--[[--
HTTP client for POST <server_url>/api/koreader/sync (SPEC §6).

Follows the exporter Readwise-target pattern: socket.http + LuaSec via
socketutil timeouts, rapidjson for both directions. Callers are responsible
for network state (NetworkMgr); this module just performs one request.
]]

local Device = require("device")
local http = require("socket.http")
local logger = require("logger")
local ltn12 = require("ltn12")
local rapidjson = require("rapidjson")
local socket = require("socket")
local socketutil = require("socketutil")
local _ = require("gettext")

-- The version lives in _meta.lua (the one place KOReader and the appstore
-- plugin read); load it from the file next to this one rather than keeping
-- a second copy. _meta.lua must stay standalone, so the dependency can only
-- point this way.
local function metaVersion()
    local here = debug.getinfo(1, "S").source:match("^@(.*)/[^/]+$")
    local ok, meta = pcall(dofile, here .. "/_meta.lua")
    return ok and meta.version or "0.0.0"
end

local Api = {
    VERSION = metaVersion(),
}

--[[--
Push one or several books.

@param server_url e.g. "https://books.rixx.de" (no trailing slash needed)
@param api_key bearer token
@param books array of book payload tables (from scriptorium_collect)
@return results array (per-book, see SPEC §6), or nil + error message +
        HTTP status code (nil for pre-HTTP failures like encoding errors).
]]
function Api.sync(server_url, api_key, books)
    -- Trailing slash is mandatory: Django's APPEND_SLASH cannot redirect a
    -- POST, so the slash-less URL 500s server-side.
    local url = server_url:gsub("/+$", "") .. "/api/koreader/sync/"
    local payload = {
        plugin_version = Api.VERSION,
        device = {
            id = G_reader_settings:readSetting("device_id") or "unknown",
            model = Device.model or "unknown",
        },
        books = rapidjson.array(books),
    }
    local body, encode_err = rapidjson.encode(payload)
    if not body then
        return nil, _("Could not encode payload: ") .. tostring(encode_err)
    end

    local sink = {}
    -- Large-block timeouts: highlight-heavy payloads can be big (SPEC §5.6).
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(
        1,
        http.request {
            url = url,
            method = "POST",
            headers = {
                ["Authorization"] = "Bearer " .. api_key,
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
                ["Accept"] = "application/json",
            },
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(sink),
        }
    )
    socketutil:reset_timeout()

    logger.dbg("scriptorium: POST", url, "->", code)
    if headers == nil then
        return nil, _("Network error: ") .. tostring(status or code)
    end

    local content = table.concat(sink)
    if code == 200 then
        local ok, result = pcall(rapidjson.decode, content)
        if not ok or type(result) ~= "table" or type(result.results) ~= "table" then
            logger.warn("scriptorium: unparseable server response:", content:sub(1, 200))
            return nil, _("Server response was not valid JSON"), code
        end
        return result.results
    elseif code == 401 then
        return nil, _("Authentication failed — check the API token"), code
    elseif code == 413 then
        return nil, _("Payload too large for the server"), code
    elseif code == 426 then
        return nil, _("This plugin version is too old for the server — please update it"), code
    else
        logger.warn("scriptorium: server error", code, content:sub(1, 500))
        return nil, _("Server error ") .. tostring(code), code
    end
end

return Api
