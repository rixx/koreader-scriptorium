-- Stub-based tests for scriptorium_opds.lua: feed reading and the pull loop.
-- Plain luajit, no KOReader checkout; run from the repo root:
--     luajit tests/test_opds.lua
-- Not covered: the subprocess/UIManager plumbing, the real OPDSParser and socket.http.

local function file_mode(path)
    if os.execute('test -d "' .. path .. '"') == 0 then
        return "directory"
    end
    local fh = io.open(path, "rb")
    if fh then
        fh:close()
        return "file"
    end
end

local function read_file(path)
    local fh = io.open(path, "rb")
    if not fh then
        return nil
    end
    local data = fh:read("*a")
    fh:close()
    return data
end

local function write_file(path, data)
    local fh = assert(io.open(path, "wb"))
    fh:write(data)
    fh:close()
end

-- Fake server: URL -> { code, body }. Each test replaces it.
local server_routes = {}
local requests = {}

local function preload(name, value)
    package.preload[name] = function()
        return value
    end
end

local noop = setmetatable({}, {
    __index = function()
        return function() end
    end,
})

preload("datastorage", {
    getSettingsDir = function()
        return os.getenv("TMPDIR") or "/tmp"
    end,
})
preload("ui/widget/infomessage", {
    new = function(_, o)
        return o
    end,
})
preload("luasettings", {
    open = function()
        return {
            readSetting = function(_, _, default)
                return default
            end,
            saveSetting = function() end,
            flush = function() end,
        }
    end,
})
preload("ui/network/manager", {
    isOnline = function()
        return false
    end,
})
preload("ui/uimanager", { scheduleIn = function() end, unschedule = function() end, broadcastEvent = function() end })
preload("logger", noop)
preload("gettext", function(s)
    return s
end)
preload("ffi/util", {
    template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d)", function(i)
            return tostring(args[tonumber(i)])
        end))
    end,
})
preload("libs/libkoreader-lfs", {
    attributes = function(path, field)
        local mode = file_mode(path)
        if not mode then
            return nil
        end
        if field == "mode" then
            return mode
        end
        if field == "size" then
            return #(read_file(path) or "")
        end
        return { mode = mode }
    end,
})
preload("util", {
    getFileNameSuffix = function(file)
        return file:match("%.([^./]+)$") or ""
    end,
    replaceAllInvalidChars = function(str)
        return (str:gsub('[\\/:*?"<>|]', "_"):gsub("[.%s]+$", ""))
    end,
    getSafeFilename = function(str)
        return (str:gsub("/", "_"))
    end,
    gsplit = function(str, sep)
        return str:gmatch("([^" .. sep .. "]+)")
    end,
    trim = function(s)
        return (s:gsub("^%s+", ""):gsub("%s+$", ""))
    end,
})
preload("document/documentregistry", {
    hasProvider = function(_, file, mimetype)
        if file then
            local ext = file:match("%.(%w+)$")
            return ext == "epub" or ext == "pdf"
        end
        return mimetype == "application/epub+zip" or mimetype == "application/pdf"
    end,
    mimeToExt = function(_, mimetype)
        return ({ ["application/epub+zip"] = "epub", ["application/pdf"] = "pdf" })[mimetype]
    end,
})
preload("socket.url", {
    absolute = function(base, href)
        if href:match("^%a+://") then
            return href
        end
        return base:match("^(%a+://[^/]+)") .. href
    end,
})
preload(
    "socketutil",
    { set_timeout = function() end, reset_timeout = function() end, FILE_BLOCK_TIMEOUT = 1, FILE_TOTAL_TIMEOUT = 1 }
)
preload("ltn12", {
    sink = {
        table = function(t)
            return function(chunk)
                if chunk then
                    table.insert(t, chunk)
                end
                return 1
            end
        end,
        file = function(fh)
            return function(chunk)
                if chunk then
                    fh:write(chunk)
                else
                    fh:close()
                end
                return 1
            end
        end,
    },
})
preload("socket.http", {
    request = function(req)
        table.insert(requests, { url = req.url, user = req.user, password = req.password })
        local route = server_routes[req.url] or { code = 404, body = "not found" }
        req.sink(route.body)
        req.sink(nil)
        return 1, route.code
    end,
})
-- The real parser's output shape: { feed = { link = {...}, entry = {...} } }; tests
-- hand over already-parsed tables as the "body" of feed URLs.
preload("opdsparser", {
    parse = function(_, text)
        local feed = assert(loadstring("return " .. text))()
        return { feed = feed }
    end,
})

package.path = "scriptorium.koplugin/?.lua;" .. package.path
local Opds = require("scriptorium_opds")

local function serialize(v)
    if type(v) == "table" then
        local parts = {}
        for k, x in pairs(v) do
            table.insert(parts, "[" .. serialize(k) .. "]=" .. serialize(x))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return type(v) == "string" and string.format("%q", v) or tostring(v)
end

local function epub_entry(id, title, authors, href)
    local author = {}
    for _, name in ipairs(authors) do
        table.insert(author, { name = name })
    end
    return {
        id = id,
        title = title,
        author = author,
        link = {
            { rel = "http://opds-spec.org/image", href = "/opds/cover/" .. id, type = "image/jpeg" },
            { rel = "http://opds-spec.org/acquisition", href = href, type = "application/epub+zip" },
        },
    }
end

local tmp_root = os.tmpname()
os.remove(tmp_root)
assert(os.execute('mkdir -p "' .. tmp_root .. '"') == 0)

local function fresh_dir(name)
    local dir = tmp_root .. "/" .. name
    assert(os.execute('mkdir -p "' .. dir .. '"') == 0)
    return dir
end

local tests, failures = {}, 0
local function test(name, fn)
    table.insert(tests, { name = name, fn = fn })
end

local function eq(actual, expected, what)
    if actual ~= expected then
        error(string.format("%s: expected %s, got %s", what or "value", tostring(expected), tostring(actual)), 2)
    end
end

local function listdir(dir)
    local p = io.popen('ls -A "' .. dir .. '"')
    local names = {}
    for line in p:lines() do
        table.insert(names, line)
    end
    p:close()
    table.sort(names)
    return table.concat(names, "|")
end

-- readPage ---------------------------------------------------------------

test("readPage: calibre-web entry, relative href, multiple authors, next link", function()
    local feed = {
        link = {
            { rel = "self", href = "/opds/category/3" },
            { rel = "next", href = "/opds/category/3?offset=30" },
        },
        entry = {
            {
                id = "urn:uuid:aaa",
                title = "Good Omens",
                author = { { name = "Terry Pratchett" }, { name = "Neil Gaiman" } },
                link = {
                    {
                        rel = "http://opds-spec.org/acquisition",
                        href = "/opds/download/7/epub/",
                        type = "application/epub+zip",
                    },
                    {
                        rel = "http://opds-spec.org/acquisition",
                        href = "/opds/download/7/pdf/",
                        type = "application/pdf",
                    },
                },
            },
        },
    }
    local books, next_url = Opds.readPage(feed, "https://cw.example/opds/category/3", nil)
    eq(#books, 1, "books")
    eq(books[1].key, "urn:uuid:aaa", "key")
    eq(books[1].href, "https://cw.example/opds/download/7/epub/", "href")
    eq(books[1].ext, "epub", "ext from mimetype")
    eq(books[1].name, "Terry Pratchett, Neil Gaiman - Good Omens", "name")
    eq(next_url, "https://cw.example/opds/category/3?offset=30", "next")
end)

test("readPage: file type filter picks the second format", function()
    local feed = { entry = { epub_entry("urn:uuid:b", "T", { "A" }, "/d/1/epub/") } }
    table.insert(
        feed.entry[1].link,
        { rel = "http://opds-spec.org/acquisition", href = "/d/1/pdf/", type = "application/pdf" }
    )
    local books = Opds.readPage(feed, "https://cw.example/x", { pdf = true })
    eq(#books, 1, "books")
    eq(books[1].ext, "pdf", "ext")
end)

test("readPage: skips navigation entries, borrow links, unknown types, no next on last page", function()
    local feed = {
        entry = {
            {
                id = "/opds/category/3",
                title = "Fantasy",
                link = { { rel = "subsection", href = "/opds/category/3", type = "application/atom+xml" } },
            },
            {
                id = "urn:uuid:c",
                title = "Lent",
                link = {
                    {
                        rel = "http://opds-spec.org/acquisition/borrow",
                        href = "/borrow/1",
                        type = "application/epub+zip",
                    },
                },
            },
            {
                id = "urn:uuid:d",
                title = "Comic",
                link = { { rel = "http://opds-spec.org/acquisition", href = "/d/2/cbz/", type = "application/x-cbz" } },
            },
        },
    }
    local books, next_url = Opds.readPage(feed, "https://cw.example/x", nil)
    eq(#books, 0, "books")
    eq(next_url, nil, "next")
end)

test("readPage: entry without id keys on href, without author or title still named", function()
    local feed = {
        entry = { { link = { { rel = "http://opds-spec.org/acquisition", href = "https://other.example/b.epub" } } } },
    }
    local books = Opds.readPage(feed, "https://cw.example/x", nil)
    eq(books[1].key, "https://other.example/b.epub", "key")
    eq(books[1].ext, "epub", "ext from suffix")
    eq(books[1].name, "Unknown", "name")
end)

test("entryName: older parser shape, single author table instead of a list", function()
    eq(
        Opds.entryName({ title = "A Dragon of a Different Color", author = { name = "Rachel Aaron" } }),
        "Rachel Aaron - A Dragon of a Different Color",
        "name"
    )
end)

test("entryName: invalid filename characters replaced", function()
    eq(Opds.entryName({ title = 'What? A/B: "C"', author = { { name = "X" } } }), "X - What_ A_B_ _C_", "name")
end)

-- runSync ----------------------------------------------------------------

local function feed_body(entries, next_href)
    local feed = { entry = entries, link = next_href and { { rel = "next", href = next_href } } or {} }
    return serialize(feed)
end

local function catalog(dir, url)
    return {
        title = "Calibre",
        url = url or "https://cw.example/opds/category/3",
        username = "u",
        password = "p",
        sync = true,
        sync_dir = dir,
    }
end

test("runSync: downloads new books, sends credentials, leaves no .part", function()
    local dir = fresh_dir("new")
    requests = {}
    server_routes = {
        ["https://cw.example/opds/category/3"] = {
            code = 200,
            body = feed_body({ epub_entry("urn:uuid:1", "One", { "A" }, "/d/1/epub/") }),
        },
        ["https://cw.example/d/1/epub/"] = { code = 200, body = "EPUB1" },
    }
    local result = Opds.runSync({ catalog(dir) }, {}, {})
    eq(result.downloaded, 1, "downloaded")
    eq(#result.errors, 0, "errors")
    eq(read_file(dir .. "/A - One.epub"), "EPUB1", "content")
    eq(listdir(dir), "A - One.epub", "dir listing")
    eq(result.pulled["urn:uuid:1"].file, dir .. "/A - One.epub", "recorded file")
    eq(requests[2].user, "u", "user")
    eq(requests[2].password, "p", "password")
end)

test("runSync: book in ledger is not pulled again after deletion", function()
    local dir = fresh_dir("ledger")
    requests = {}
    server_routes = {
        ["https://cw.example/opds/category/3"] = {
            code = 200,
            body = feed_body({ epub_entry("urn:uuid:1", "One", { "A" }, "/d/1/epub/") }),
        },
        ["https://cw.example/d/1/epub/"] = { code = 200, body = "EPUB1" },
    }
    local result = Opds.runSync({ catalog(dir) }, {}, { ["urn:uuid:1"] = true })
    eq(result.downloaded, 0, "downloaded")
    eq(next(result.pulled), nil, "nothing newly recorded")
    eq(#requests, 1, "only the feed was fetched")
    eq(listdir(dir), "", "dir listing")
end)

test("runSync: existing file is recorded, never overwritten", function()
    local dir = fresh_dir("present")
    write_file(dir .. "/A - One.epub", "MINE")
    requests = {}
    server_routes = {
        ["https://cw.example/opds/category/3"] = {
            code = 200,
            body = feed_body({ epub_entry("urn:uuid:1", "One", { "A" }, "/d/1/epub/") }),
        },
        ["https://cw.example/d/1/epub/"] = { code = 200, body = "EPUB1" },
    }
    local result = Opds.runSync({ catalog(dir) }, {}, {})
    eq(result.downloaded, 0, "downloaded")
    eq(result.pulled["urn:uuid:1"].downloaded, false, "marked as present")
    eq(read_file(dir .. "/A - One.epub"), "MINE", "content untouched")
    eq(#requests, 1, "no download request")
end)

test("runSync: failed download leaves nothing behind and is not recorded", function()
    local dir = fresh_dir("fail")
    server_routes = {
        ["https://cw.example/opds/category/3"] = {
            code = 200,
            body = feed_body({
                epub_entry("urn:uuid:1", "One", { "A" }, "/d/1/epub/"),
                epub_entry("urn:uuid:2", "Two", { "A" }, "/d/2/epub/"),
            }),
        },
        ["https://cw.example/d/1/epub/"] = { code = 500, body = "<html>Internal Server Error</html>" },
        ["https://cw.example/d/2/epub/"] = { code = 200, body = "EPUB2" },
    }
    local result = Opds.runSync({ catalog(dir) }, {}, {})
    eq(result.downloaded, 1, "downloaded")
    eq(result.pulled["urn:uuid:1"], nil, "failed book not recorded")
    eq(#result.errors, 1, "errors")
    eq(listdir(dir), "A - Two.epub", "dir listing")
end)

test("runSync: empty 200 body is a failure, not an empty book", function()
    local dir = fresh_dir("empty")
    server_routes = {
        ["https://cw.example/opds/category/3"] = {
            code = 200,
            body = feed_body({ epub_entry("urn:uuid:1", "One", { "A" }, "/d/1/epub/") }),
        },
        ["https://cw.example/d/1/epub/"] = { code = 200, body = "" },
    }
    local result = Opds.runSync({ catalog(dir) }, {}, {})
    eq(result.downloaded, 0, "downloaded")
    eq(result.pulled["urn:uuid:1"], nil, "not recorded")
    eq(listdir(dir), "", "dir listing")
end)

test("runSync: feed error records nothing", function()
    local dir = fresh_dir("feed500")
    server_routes = { ["https://cw.example/opds/category/3"] = { code = 401, body = "Unauthorized" } }
    local result = Opds.runSync({ catalog(dir) }, {}, {})
    eq(result.downloaded, 0, "downloaded")
    eq(#result.errors, 1, "errors")
    eq(next(result.pulled), nil, "nothing recorded")
end)

test("runSync: garbage feed body is an error, not a crash", function()
    local dir = fresh_dir("garbage")
    server_routes = { ["https://cw.example/opds/category/3"] = { code = 200, body = "<html><body>login" } }
    local result = Opds.runSync({ catalog(dir) }, {}, {})
    eq(#result.errors, 1, "errors")
end)

test("runSync: follows pages, stops on a next link that loops back", function()
    local dir = fresh_dir("pages")
    requests = {}
    server_routes = {
        ["https://cw.example/opds/category/3"] = {
            code = 200,
            body = feed_body({ epub_entry("urn:uuid:1", "One", { "A" }, "/d/1/epub/") }, "/opds/category/3?offset=1"),
        },
        ["https://cw.example/opds/category/3?offset=1"] = {
            code = 200,
            body = feed_body({ epub_entry("urn:uuid:2", "Two", { "A" }, "/d/2/epub/") }, "/opds/category/3"),
        },
        ["https://cw.example/d/1/epub/"] = { code = 200, body = "EPUB1" },
        ["https://cw.example/d/2/epub/"] = { code = 200, body = "EPUB2" },
    }
    local result = Opds.runSync({ catalog(dir) }, {}, {})
    eq(result.downloaded, 2, "downloaded")
    eq(#requests, 4, "two pages, two books, no loop")
end)

test("runSync: max files per run caps downloads across catalogs", function()
    local dir = fresh_dir("cap")
    server_routes = {
        ["https://cw.example/a"] = {
            code = 200,
            body = feed_body({
                epub_entry("urn:uuid:1", "One", { "A" }, "/d/1/epub/"),
                epub_entry("urn:uuid:2", "Two", { "A" }, "/d/2/epub/"),
                epub_entry("urn:uuid:3", "Three", { "A" }, "/d/3/epub/"),
            }),
        },
        ["https://cw.example/b"] = {
            code = 200,
            body = feed_body({ epub_entry("urn:uuid:4", "Four", { "A" }, "/d/4/epub/") }),
        },
        ["https://cw.example/d/1/epub/"] = { code = 200, body = "1" },
        ["https://cw.example/d/2/epub/"] = { code = 200, body = "2" },
        ["https://cw.example/d/3/epub/"] = { code = 200, body = "3" },
        ["https://cw.example/d/4/epub/"] = { code = 200, body = "4" },
    }
    requests = {}
    local result = Opds.runSync(
        { catalog(dir, "https://cw.example/a"), catalog(dir, "https://cw.example/b") },
        { sync_max_dl = 2 },
        {}
    )
    eq(result.downloaded, 2, "downloaded")
    eq(result.pulled["urn:uuid:3"], nil, "third left for the next run")
    eq(#requests, 3, "second catalog not fetched")
end)

test("runSync: same book in two catalogs with their own folders is downloaded once", function()
    local dir_a, dir_b = fresh_dir("twice-a"), fresh_dir("twice-b")
    requests = {}
    local body = feed_body({ epub_entry("urn:uuid:1", "One", { "A" }, "/d/1/epub/") })
    server_routes = {
        ["https://cw.example/a"] = { code = 200, body = body },
        ["https://cw.example/b"] = { code = 200, body = body },
        ["https://cw.example/d/1/epub/"] = { code = 200, body = "1" },
    }
    local result = Opds.runSync(
        { catalog(dir_a, "https://cw.example/a"), catalog(dir_b, "https://cw.example/b") },
        {},
        {}
    )
    eq(result.downloaded, 1, "downloaded")
    eq(#requests, 3, "two feeds, one download")
    eq(listdir(dir_b), "", "second folder empty")
end)

test("runSync: missing sync folder is an error, global folder is the fallback", function()
    local dir = fresh_dir("global")
    server_routes = {
        ["https://cw.example/opds/category/3"] = {
            code = 200,
            body = feed_body({ epub_entry("urn:uuid:1", "One", { "A" }, "/d/1/epub/") }),
        },
        ["https://cw.example/d/1/epub/"] = { code = 200, body = "1" },
    }
    local missing = catalog(tmp_root .. "/does-not-exist")
    local result = Opds.runSync({ missing }, {}, {})
    eq(#result.errors, 1, "errors")
    eq(result.downloaded, 0, "downloaded")

    local fallback = catalog(nil)
    result = Opds.runSync({ fallback }, { sync_dir = dir }, {})
    eq(result.downloaded, 1, "downloaded into global folder")
    eq(listdir(dir), "A - One.epub", "dir listing")
end)

for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        print("ok   " .. t.name)
    else
        failures = failures + 1
        print("FAIL " .. t.name .. "\n     " .. tostring(err))
    end
end
os.execute('rm -rf "' .. tmp_root .. '"')
print(string.format("%d tests, %d failures", #tests, failures))
os.exit(failures == 0 and 0 or 1)
