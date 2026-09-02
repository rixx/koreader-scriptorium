-- Smoke test for scriptorium_wallpaper.lua against a real temp directory.
local files = {}
local dirs = {}

package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function(path, what)
            assert(what == "mode")
            if dirs[path] then
                return "directory"
            end
            return files[path] and "file" or nil
        end,
        dir = function(path)
            if not dirs[path] then
                error("no such directory: " .. path)
            end
            local names = { ".", ".." }
            for file in pairs(files) do
                local dir, name = file:match("^(.*)/([^/]+)$")
                if dir == path then
                    table.insert(names, name)
                end
            end
            table.sort(names)
            local i = 0
            return function()
                i = i + 1
                return names[i]
            end
        end,
    }
end
package.preload["ffi/util"] = function()
    return {
        copyFile = function(from, to)
            if not files[from] then
                return "no such file: " .. from
            end
            files[to] = files[from]
            return nil
        end,
    }
end
package.preload["ffi/sha2"] = function()
    -- Not MD5; the module only needs a stable hex digest of the path.
    return {
        md5 = function(s)
            local h = 5381
            for i = 1, #s do
                h = (h * 33 + s:byte(i)) % 0xFFFFFFFF
            end
            return string.format("%08x%024x", h, 0)
        end,
    }
end
package.preload["logger"] = function()
    return { warn = print, info = print, dbg = function() end }
end
package.preload["datastorage"] = function()
    return {
        getDataDir = function()
            return "/sdcard/koreader"
        end,
    }
end

package.path = "scriptorium.koplugin/?.lua;" .. package.path
local Wallpaper = require("scriptorium_wallpaper")

local real_remove = os.remove
os.remove = function(path) -- luacheck: ignore
    files[path] = nil
    return true
end

local failures = 0
local function check(cond, msg)
    if cond then
        print("PASS " .. msg)
    else
        failures = failures + 1
        print("FAIL " .. msg)
    end
end

local WALL = "/sdcard/Wallpaper"
local SRC = "/sdcard/koreader/cover.jpg"

local function reset()
    files = { [SRC] = "cover-bytes" }
    dirs = { [WALL] = true }
end

-- 1. Publishes under a per-book name, extension taken from the source
reset()
local target, err = Wallpaper.publish(WALL, SRC, "/books/a.epub")
check(target ~= nil, "publish returns a target (" .. tostring(err) .. ")")
check(target:match("^" .. WALL .. "/cover%-%x+%.jpg$") ~= nil, "target is <dir>/cover-<hash>.jpg")
check(files[target] == "cover-bytes", "cover bytes copied")

-- 2. Different books get different names
local a = Wallpaper.nameFor("/books/a.epub", SRC)
local b = Wallpaper.nameFor("/books/b.epub", SRC)
check(a ~= b, "different books get different filenames")
check(a == Wallpaper.nameFor("/books/a.epub", SRC), "same book keeps its filename")

-- 3. Publishing a second book leaves exactly one cover behind
reset()
Wallpaper.publish(WALL, SRC, "/books/a.epub")
local second = Wallpaper.publish(WALL, SRC, "/books/b.epub")
local left = {}
for path in pairs(files) do
    if path:match("^" .. WALL .. "/") then
        table.insert(left, path)
    end
end
check(#left == 1 and left[1] == second, "the previous book's cover is pruned")

-- 4. Unrelated files in the folder are left alone
reset()
files[WALL .. "/holiday.jpg"] = "keep me"
Wallpaper.publish(WALL, SRC, "/books/a.epub")
check(files[WALL .. "/holiday.jpg"] == "keep me", "files without the prefix survive")

-- 5. Refusals, none of which may raise
reset()
check(select(2, Wallpaper.publish("", SRC, "/books/a.epub")) == "disabled", "empty folder disables")
check(select(2, Wallpaper.publish(WALL, SRC, nil)) == "no source", "no document is a no-op")
check(
    select(2, Wallpaper.publish(WALL, "/sdcard/gone.jpg", "/books/a.epub")):match("^no cover image"),
    "missing cover image is reported"
)
check(
    select(2, Wallpaper.publish("/sdcard/Nope", SRC, "/books/a.epub")):match("^no such folder"),
    "missing folder is reported"
)
check(Wallpaper.publishQuietly("", SRC, "/books/a.epub") == nil, "publishQuietly swallows refusals")

-- 6. A trailing slash on the folder does not double up
reset()
check(Wallpaper.publish(WALL .. "/", SRC, "/books/a.epub") == target, "trailing slash is trimmed")

-- 7. The coverimage export is kept out of the folder the picker lists
local function settingsStub(value)
    local store = { cover_image_path = value }
    return {
        readSetting = function(_, key)
            return store[key]
        end,
        saveSetting = function(_, key, v)
            store[key] = v
        end,
    },
        store
end

local outside, store = settingsStub("/sdcard/koreader/mine.jpg")
check(Wallpaper.ensureSourceOutside(WALL, outside) == "/sdcard/koreader/mine.jpg", "a path outside the folder is kept")

local inside
inside, store = settingsStub(WALL .. "/book.jpg")
check(Wallpaper.ensureSourceOutside(WALL, inside) == SRC, "a path inside the folder is moved out")
check(store.cover_image_path == SRC, "the move is persisted")

local unset
unset, store = settingsStub(nil)
check(Wallpaper.ensureSourceOutside(WALL, unset) == SRC, "an unset path gets the default")

local disabled = settingsStub(WALL .. "/book.jpg")
check(Wallpaper.ensureSourceOutside("", disabled) == WALL .. "/book.jpg", "no folder, no repair")

check(Wallpaper.isInside(WALL .. "/", WALL .. "/x.jpg"), "isInside ignores a trailing slash")
check(not Wallpaper.isInside(WALL, WALL .. "sibling/x.jpg"), "isInside does not match a sibling prefix")

os.remove = real_remove -- luacheck: ignore
print(failures == 0 and "all tests passed" or (failures .. " test(s) failed"))
os.exit(failures == 0 and 0 or 1)
