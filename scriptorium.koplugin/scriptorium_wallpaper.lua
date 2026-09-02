--[[--
Republish the current book's cover under a filename that changes with the
book, for lockscreen pickers that cache by path.

The Moaan/inkPalm picker copies the chosen image to data/mogu/<hash of the
image's path>.png and skips the copy when the stored path already contains
that hash. A fixed export path therefore pins the lockscreen to the first
cover ever selected. Giving each book its own filename makes one tap in the
picker apply the current cover.

The source is whatever KOReader's coverimage plugin wrote
(cover_image_path); this runs after it, on the same event. That path must sit
outside the target folder, or the picker lists the stale copy alongside the
fresh one — ensureSourceOutside enforces it.
]]

local DataStorage = require("datastorage")
local ffiutil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local md5 = require("ffi/sha2").md5

local Wallpaper = {}

Wallpaper.PREFIX = "cover-"

-- Android's user storage root, where the inkPalm's picker looks.
Wallpaper.DEFAULT_DIR = "/storage/emulated/0/Wallpaper"

function Wallpaper.defaultSource()
    return DataStorage:getDataDir() .. "/cover.jpg"
end

function Wallpaper.isInside(dir, path)
    dir = dir:gsub("/+$", "")
    return path:sub(1, #dir + 1) == dir .. "/"
end

-- Point the coverimage plugin's export outside the folder the picker lists.
-- Returns the path it settled on. The running CoverImage instance read
-- cover_image_path at its own init, so a repair takes effect one restart later.
function Wallpaper.ensureSourceOutside(dir, settings)
    local current = settings:readSetting("cover_image_path")
    if current and current ~= "" and not (dir ~= "" and Wallpaper.isInside(dir, current)) then
        return current
    end
    local source = Wallpaper.defaultSource()
    settings:saveSetting("cover_image_path", source)
    logger.info("scriptorium: cover_image_path set to " .. source)
    return source
end

local function extensionOf(path)
    return path:match("%.(%w+)$") or "jpg"
end

-- Keyed on the document, not the image bytes: reopening a book must not
-- invalidate the picker's selection.
function Wallpaper.nameFor(doc_path, source_path)
    return Wallpaper.PREFIX .. md5(doc_path):sub(1, 8) .. "." .. extensionOf(source_path)
end

-- Drop the covers written for other books; the picker should show one image.
function Wallpaper.prune(dir, keep)
    if lfs.attributes(dir, "mode") ~= "directory" then
        return
    end
    for entry in lfs.dir(dir) do
        if entry ~= keep and entry:sub(1, #Wallpaper.PREFIX) == Wallpaper.PREFIX then
            os.remove(dir .. "/" .. entry)
        end
    end
end

-- Returns the path written, or nil plus a reason.
function Wallpaper.publish(dir, source_path, doc_path)
    if not dir or dir == "" then
        return nil, "disabled"
    end
    if not doc_path or not source_path or source_path == "" then
        return nil, "no source"
    end
    if lfs.attributes(source_path, "mode") ~= "file" then
        return nil, "no cover image at " .. source_path
    end
    dir = dir:gsub("/+$", "")
    if lfs.attributes(dir, "mode") ~= "directory" then
        return nil, "no such folder: " .. dir
    end
    local name = Wallpaper.nameFor(doc_path, source_path)
    local target = dir .. "/" .. name
    local err = ffiutil.copyFile(source_path, target)
    if err then
        return nil, err
    end
    Wallpaper.prune(dir, name)
    return target
end

-- Fire-and-forget wrapper: never let a wallpaper problem disturb a book open.
function Wallpaper.publishQuietly(dir, source_path, doc_path)
    local target, err = Wallpaper.publish(dir, source_path, doc_path)
    if target then
        logger.dbg("scriptorium: cover published to " .. target)
    elseif err and err ~= "disabled" then
        logger.warn("scriptorium: cover not published: " .. err)
    end
    return target
end

return Wallpaper
