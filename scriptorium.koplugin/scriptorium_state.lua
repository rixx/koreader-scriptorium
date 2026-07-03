--[[--
Plugin state persistence: settings, pushed-books table, scan cache.

Lives in its own LuaSettings file (<settings dir>/scriptorium.lua), never in
G_reader_settings. A module-level singleton is shared between the ReaderUI
and FileManager plugin instances, so both mutate the same in-memory table and
can't clobber each other's flushes.
]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")

local State = {}
State.__index = State

local DEFAULTS = {
    server_url = "https://books.rixx.de",
    api_key = "",
    periodic_sync = true,
    push_on_finish = false,
    push_abandoned = false,
}

local instance = nil

function State.open()
    if not instance then
        instance = setmetatable({
            settings = LuaSettings:open(DataStorage:getSettingsDir() .. "/scriptorium.lua"),
        }, State)
    end
    return instance
end

function State:get(key)
    local value = self.settings:readSetting(key)
    if value == nil then
        return DEFAULTS[key]
    end
    return value
end

function State:set(key, value)
    self.settings:saveSetting(key, value)
    self.dirty = true
end

function State:toggle(key)
    self:set(key, not self:get(key))
end

-- pushed[md5] = { modified = "YYYY-MM-DD", fingerprint = "...", pushed_at = <unix ts> }
-- The plugin's entire memory of what the server already has (SPEC §5.2).
function State:pushed()
    return self.settings:readSetting("pushed", {})
end

function State:recordPushed(md5, modified, fingerprint)
    self:pushed()[md5] = {
        modified = modified,
        fingerprint = fingerprint,
        pushed_at = os.time(),
    }
    self.dirty = true
end

function State:pushedCount()
    local n = 0
    for _ in pairs(self:pushed()) do
        n = n + 1
    end
    return n
end

-- scan_cache[book_path] = sidecar mtime at last (non-pending) inspection
function State:scanCache()
    return self.settings:readSetting("scan_cache", {})
end

function State:setScanCache(path, mtime)
    self:scanCache()[path] = mtime
    self.dirty = true
end

function State:flush()
    if self.dirty then
        self.settings:flush()
        self.dirty = nil
    end
end

return State
