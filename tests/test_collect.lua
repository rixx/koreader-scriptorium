-- Smoke test for scriptorium_collect.lua with stubbed KOReader modules.
package.preload["datastorage"] = function()
    return {
        getSettingsDir = function()
            return "/nonexistent-settings-dir"
        end,
    }
end
package.preload["lua-ljsqlite3/init"] = function()
    return {
        open = function()
            error("stats DB must not be opened in this test")
        end,
    }
end
package.preload["libs/libkoreader-lfs"] = function()
    return {
        attributes = function()
            return nil
        end,
    }
end
package.preload["logger"] = function()
    return { warn = print, info = print, dbg = function() end }
end
package.preload["rapidjson"] = function()
    return {
        array = function(t)
            rawset(t, "__is_array", true)
            return t
        end,
    }
end

package.path = "scriptorium.koplugin/?.lua;" .. package.path
local Collect = require("scriptorium_collect")

local function DS(data)
    return {
        readSetting = function(_, key)
            return data[key]
        end,
    }
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

-- 1. Full payload for a finished book
local annotations = {
    {
        datetime = "2026-06-01 10:00:00",
        drawer = "lighten",
        color = "yellow",
        text = "first highlight",
        chapter = "Ch 1",
        pageno = 12,
        pos0 = "xp0",
        pos1 = "xp1",
    },
    { datetime = "2026-06-02 11:00:00" }, -- plain page bookmark, no drawer
    {
        datetime = "2026-06-03 12:00:00",
        datetime_updated = "2026-06-05 09:00:00",
        drawer = "underscore",
        text = "second",
        note = "a note",
        pageno = 40,
    },
}
local ds = DS {
    partial_md5_checksum = "8a1a4d0d64d09761b0eb0e3d97e4e848",
    annotations = annotations,
    doc_pages = 304,
    doc_path = "/books/le-guin.epub",
    summary = { status = "complete", modified = "2026-07-01", rating = 5, note = "great" },
    doc_props = {
        title = "The Left Hand of Darkness",
        authors = "Ursula K. Le Guin\nSomeone Else",
        identifiers = "ISBN:9780441478125\ncalibre:1234",
        language = "en",
        series = "Hainish Cycle",
        series_index = "6",
    },
}
local book, fp = Collect.bookPayload(ds)
check(book ~= nil, "payload built")
check(book.md5 == "8a1a4d0d64d09761b0eb0e3d97e4e848", "md5")
check(book.title == "The Left Hand of Darkness", "title")
check(#book.authors == 2 and book.authors[2] == "Someone Else", "authors split on newline")
check(#book.identifiers == 2 and book.identifiers[1] == "ISBN:9780441478125", "identifiers split")
check(book.series_index == 6, "series_index numeric")
check(book.status == "complete" and book.finished_on == "2026-07-01", "status + finished_on")
check(book.rating == 5 and book.summary_note == "great", "rating + note")
check(book.pages == 304, "pages")
check(book.started_on == nil and book.total_time_seconds == nil, "stats absent without DB")
check(#book.highlights == 2, "bookmark filtered out")
check(book.highlights[1].text == "first highlight", "highlight text kept")
check(book.highlights[1].pos0 == nil and book.highlights[1].page == nil, "position internals stripped")
check(book.highlights[2].note == "a note", "note kept")
check(book.highlights.__is_array, "highlights marked as JSON array")
check(
    fp == "2:2026-06-05 09:00:00",
    "fingerprint counts highlights, uses latest datetime_updated, got: " .. tostring(fp)
)

-- 2. Fingerprint changes when a highlight is edited
annotations[3].datetime_updated = "2026-06-06 10:00:00"
local _, fp2 = Collect.bookPayload(ds)
check(fp2 ~= fp, "fingerprint changes on highlight edit")

-- 3. Legacy sidecar without annotations key
local legacy_book, err = Collect.bookPayload(DS {
    partial_md5_checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    summary = { status = "complete", modified = "2020-01-01" },
})
check(legacy_book == nil and err:match("legacy"), "legacy sidecar rejected: " .. tostring(err))

-- 4. Sidecar without md5
local nomd5, err2 = Collect.bookPayload(DS { annotations = {} })
check(nomd5 == nil and err2:match("md5"), "missing md5 rejected")

-- 5. Defaults: rating 0 dropped, empty note dropped, title fallback from path
local sparse, fp3 = Collect.bookPayload(DS {
    partial_md5_checksum = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    annotations = {},
    doc_path = "/books/some file.epub",
    summary = { status = "complete", modified = "2026-07-02", rating = 0, note = "" },
})
check(sparse.title == "some file", "title falls back to filename")
check(sparse.rating == nil and sparse.summary_note == nil, "zero rating and empty note dropped")
check(#sparse.authors == 0 and sparse.authors.__is_array, "authors empty array when missing")
check(#sparse.highlights == 0, "no highlights ok")
check(fp3 == "0:", "empty fingerprint")

-- 5b. Server-schema guards: unfinished status, missing finish date, bad md5
local unfinished, err3 = Collect.bookPayload(DS {
    partial_md5_checksum = ("c"):rep(32),
    annotations = {},
    summary = { status = "reading" },
})
check(unfinished == nil and err3:match("not marked as finished"), "unfinished book refused client-side")
local nodate, err4 = Collect.bookPayload(DS {
    partial_md5_checksum = ("d"):rep(32),
    annotations = {},
    summary = { status = "complete" },
})
check(nodate == nil and err4:match("finish date"), "missing summary.modified refused")
local badmd5, err5 = Collect.bookPayload(DS {
    partial_md5_checksum = "not32chars",
    annotations = {},
    summary = { status = "complete", modified = "2026-07-01" },
})
check(badmd5 == nil and err5:match("md5"), "non-32-hex md5 refused")
local niltext = Collect.bookPayload(DS {
    partial_md5_checksum = ("f"):rep(32),
    annotations = { { drawer = "lighten", datetime = "2026-06-01 10:00:00" } },
    summary = { status = "complete", modified = "2026-07-01" },
})
check(niltext.highlights[1].text == "", "nil highlight text becomes empty string")

-- 6. readStats guards: bad md5, missing DB
local s1, t1 = Collect.readStats("not-hex!")
check(s1 == nil and t1 == nil, "readStats rejects non-hex md5")
local s2, t2 = Collect.readStats("abcdef0123456789abcdef0123456789")
check(s2 == nil and t2 == nil, "readStats handles missing DB")

print(failures == 0 and "ALL PASS" or (failures .. " FAILURES"))
os.exit(failures == 0 and 0 or 1)
