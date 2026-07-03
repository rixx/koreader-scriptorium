# scriptorium.koplugin — Plugin Spec

A KOReader plugin that pushes finished books — metadata, finished date,
aggregate reading time, and **all highlights** — to
[scriptorium](https://books.rixx.de), the personal book tracking and review
app. Highlights are the raw material for published quotes and the plot
summary, so they always travel along.

The server side (endpoint, matching, data model) is specified in the
scriptorium repo: `../scriptorium/KOREADER.md`. This file covers everything
that runs on the device.

All KOReader facts below were verified against `koreader/koreader` master and
the KoInsight source (2026-07-03); file references point at the upstream
repos.

---

## 1. Design decisions

(Confirmed with the user, 2026-07-03; rationale in the scriptorium-side spec.)

1. **Push only finished books** — no in-progress sync, no reading positions.
   Scriptorium stays the source of truth; KOReader data is always partial
   (paper/audio/other-device reads never appear here).
2. **All highlights, as a blob** — sent wholesale with every push; the server
   stores them as JSON on the `Read` row.
3. **Stats: aggregates only** — `started_on`, `finished_on`,
   `total_time_seconds`. No per-session data.
4. **Trigger: manual menu entry + periodic scan.** The scan runs on device
   lifecycle hooks, debounced (skip if the last push attempt was <60s ago).
   Unpushed finished books are rare, so a cheap "check on every hook" loop is
   the whole mechanism. Instant push-on-finish detection is an *optional*
   extra, off by default (§5.4).
5. **KOReader ≥ v2024.07 required** — only the `annotations` sidecar format
   is parsed; legacy (`highlight` + `bookmarks`) sidecars are skipped with a
   log line. Reopening an old book once migrates it automatically.

---

## 2. KOReader data (verified)

### 2.1 Sidecar file: `<book>.sdr/metadata.<ext>.lua`

A Lua table literal next to each book (default location; configurable to a
central dir). Everything we need except `started_on` lives here:

| Key | Content |
|---|---|
| `annotations` | Array of highlights/notes/bookmarks (format since **v2024.07**, PR #11563) |
| `summary` | `{status = "reading"\|"abandoned"\|"complete", rating = 1..5?, note = "...", modified = "YYYY-MM-DD"}` |
| `doc_props` | `title, authors, series, series_index, language, keywords, description, identifiers` |
| `partial_md5_checksum` | 32-hex partial MD5 of the file — KOReader's universal book identity |
| `doc_pages` | Rendered page count (pagination-dependent for EPUBs!) |
| `stats` | Statistics plugin blob incl. `total_time_in_sec`, `highlights`, `notes` counts |
| `percent_finished` | Float 0..1 |

Each annotation (`readerannotation.lua`, `buildAnnotation`):

```lua
{
  datetime = "2024-05-01 12:34:56",   -- creation time
  datetime_updated = "...",            -- optional, since 2024-12
  drawer   = "lighten",                -- highlight style; nil => plain page bookmark
  color    = "yellow",
  text     = "highlighted passage",    -- editable by user
  note     = "my note",                -- nil for plain highlights
  chapter  = "Chapter 3",              -- TOC chapter title
  pageno   = 142,                      -- continuous page number
  page     = <xpointer|page>,          -- position (engine-specific)
  pos0, pos1 = ...,                    -- position details (engine-specific)
}
```

`drawer == nil` distinguishes plain page bookmarks (skip those) from
highlights.

Key facts:

- **`doc_props.authors` and `keywords` are newline-separated** strings for
  multiple values.
- **`doc_props.identifiers` exists for EPUBs**: crengine collects all
  `<dc:identifier>` OPF entries into one **newline-separated** string, EPUB2
  entries as `scheme:value` (e.g. `ISBN:9781234567890`, `calibre:...`,
  `uuid:...`), EPUB3 entries as raw text (often `urn:isbn:...`). Many EPUBs
  only carry a uuid; PDFs/DjVu have no identifiers at all. So ISBN matching is
  a bonus, never a guarantee.
- `summary.modified` is stamped (date only) on every status change — for a
  book marked finished once, it *is* the finish date.
- **Pre-v2024.07 sidecars** use separate `highlight` + `bookmarks` tables;
  KOReader migrates them lazily when the book is opened. We don't parse the
  legacy format (decision, §1.5).

### 2.2 `statistics.sqlite3`

In the KOReader settings dir. Table `book` (`id, title, authors, series,
language, pages, md5, total_read_time, total_read_pages, highlights, notes,
last_open`) + `page_stat_data` (`id_book, page, start_time, duration,
total_pages`). `book.md5` is the same partial MD5 as the sidecar's, so it joins
cleanly. We use it for exactly two values per book:

- `total_read_time` → `total_time_seconds`
- `MIN(page_stat_data.start_time)` → `started_on`

Caveat: the plugin must ask the statistics plugin to flush in-memory data first
(`self.ui.statistics:insertDB()` — KoInsight does exactly this). If the
statistics plugin is disabled, both values are simply omitted.

### 2.3 The partial MD5 ("fastdigest")

`util.partialMD5`: MD5 over eleven 1 KiB samples at offsets
`1024 << (2*i)` for `i = -1..10`, stopping at EOF. Used by the statistics DB,
kosync, and sidecar identity. Content-based — the file path plays no role, so
the identity survives moves.

---

## 3. KoInsight: the reference implementation

[KoInsight](https://github.com/GeorgeSG/KoInsight) (MIT, Express + SQLite +
React) is a self-hosted dashboard fed by its own KOReader plugin, which uploads
the raw `statistics.sqlite3` tables plus sidecar annotations to
`POST /api/plugin/import`.

We don't use it directly (it's a parallel data silo with no scriptorium
linkage), but its plugin is the best existing reference (~1500 lines of Lua):

- `db_reader.lua` — reading `statistics.sqlite3` via `lua-ljsqlite3`,
  including the `insertDB()` flush trick.
- `annotation_reader.lua` — reading annotations from a live `ReaderUI` *or*
  from closed books via read-only `DocSettings`, keyed by partial MD5.
- `upload.lua` / `call_api.lua` — JSON POST via `socket.http` + `socketutil`
  timeouts, `NetworkMgr:runWhenOnline` wrapping, auto-sync on
  suspend/poweroff with optional "turn WiFi on, sync, restore" mode.
- The versioned payload pattern (server rejects too-old plugin versions).

KOReader's built-in exporter plugin (`plugins/exporter.koplugin`) is the other
model: its Readwise target (`target/readwise.lua`, ~100 lines) is the cleanest
example of a remote push target.

If KoInsight-style session dashboards are ever wanted, KoInsight can simply be
run *alongside* this plugin; the two don't conflict.

---

## 4. Device-side problems & risks

1. **No "book finished" event exists.** `ReaderStatus:markBook` and the book
   status widget mutate `summary.status` without broadcasting anything
   (verified by code search — there is no `BookStatusChanged` event).
   → Not a problem for us: the primary mechanism is a periodic *scan* for
   finished-but-unpushed books, not event-driven push. The optional
   instant-push feature works around it with snapshot/compare (§5.4).
2. **Highlights arrive/changed after finishing.** Users clean up highlights
   post-finish. → The plugin re-pushes automatically when the annotation
   fingerprint changes (§5.5); the server upserts idempotently and replaces
   the highlight blob wholesale.
3. **Rereads.** KOReader has one status per book; a reread means setting it
   back to "reading" then "complete" again → `summary.modified` gets a new
   date, which the plugin treats as a new unpushed finish and the server as a
   new read.
4. **API token lives on the device** in a plain LuaSettings file. Acceptable
   for a single-user personal setup over HTTPS. Server tokens are named and
   individually revocable (managed at `/b/tokens/`), so the device gets its
   own token (e.g. "inkpalm") that can be killed independently if it leaks.
5. **Moving books to a "done" directory** (via KOReader's own move UI) is
   safe. The partial MD5 hashes file *content* samples only, and KOReader's
   move carries the `.sdr` sidecar along (`DocSettings.updateLocation`,
   docsettings.lua L433) and updates the reading-history entry, so the
   periodic scan still sees the book. Only caveat: moving books with an
   *external* tool (USB file manager on a PC) strands the sidecar and breaks
   the history path — the book would silently drop out of the scan. Stick to
   KOReader's move UI for anything not yet pushed, or push first, then tidy.
6. **Legacy sidecars** (books finished before v2024.07 and never reopened)
   are skipped (§1.5).

---

## 5. Plugin design

Installed by dropping the `scriptorium.koplugin/` folder into
`koreader/plugins/`. Lua, no dependencies beyond what KOReader ships
(`socket.http` + LuaSec for HTTPS, `rapidjson`, `lua-ljsqlite3`,
`LuaSettings`).

### 5.1 Files

```
scriptorium.koplugin/
    _meta.lua                -- { fullname = "Scriptorium", description = ... }
    main.lua                 -- WidgetContainer subclass, event handlers, menu, scheduling
    scriptorium_collect.lua  -- build the push payload for one book (sidecar + stats DB)
    scriptorium_api.lua      -- HTTP client: POST /api/koreader/sync/ (Readwise-target pattern)
    scriptorium_state.lua    -- pushed-state + scan-cache persistence (LuaSettings)
```

Module files carry a `scriptorium_` prefix because KOReader appends *every*
plugin's directory to `package.path` and `package.loaded` is global — a
generic `require("api")` would silently pick up whichever plugin's `api.lua`
loaded first.

### 5.2 Settings

Own `LuaSettings` file (`<settings dir>/scriptorium.lua`):

```lua
{
  server_url = "https://books.rixx.de",
  api_key = "...",
  periodic_sync = true,         -- debounced scan-and-push on lifecycle hooks
  push_on_finish = false,       -- optional: instant push when marked complete
  push_abandoned = false,       -- also push "On hold" books as DNF reads
  pushed = { [md5] = { modified = "2026-07-01", fingerprint = "…", pushed_at = 176… } },
  scan_cache = { [path] = sdr_mtime },  -- skip unchanged sidecars cheaply
  last_attempt = 1767…,         -- unix ts of last push attempt (60s debounce)
}
```

The `pushed` table is the plugin's entire memory of what the server already
has — there is no separate pending queue: any finished book not covered by
`pushed` (or whose `modified`/`fingerprint` changed) is by definition pending,
and the next scan picks it up.

Server URL and API key editable via menu (text input dialogs, KoInsight-style).

### 5.3 Payload collection (`collect.lua`)

For the **current book** (live reader): `self.ui.doc_settings` for
`summary`, `doc_props`, `partial_md5_checksum`, `doc_pages`;
`self.ui.annotation.annotations` for highlights (filter `drawer ~= nil`);
split `authors`/`identifiers` on `\n`.

For **closed books** (periodic scan / push-all): iterate reading history
(`require("readhistory")`), open sidecars read-only via
`DocSettings:findSidecarFile(path)` + `DocSettings.openSettingsFile(sidecar)`,
select books with `summary.status == "complete"` (or `"abandoned"` if enabled).
**Never `DocSettings:open(path)`** — despite looking like a plain read, it
`os.remove`s sidecar candidate files it considers invalid (empty file, failed
parse), and the device data has no backup. `openSettingsFile` is a pure read.
Sidecars without an `annotations` key (pre-2024.07, never reopened) are
skipped with a log line — no legacy-format parsing (§1.5).

Stats: flush via `self.ui.statistics:insertDB()` when in-reader, then read
`statistics.sqlite3` with `lua-ljsqlite3`:
`SELECT total_read_time FROM book WHERE md5 = ?` and
`SELECT MIN(start_time) FROM page_stat_data WHERE id_book = ?` → `started_on`
(date of first session). All stats fields optional — plugin works with the
statistics plugin disabled.

### 5.4 Triggers

1. **Manual (menu)** — `addToMainMenu` under Tools:
   - *Push this book to Scriptorium* (reader only — force-push: bypasses the
     pushed-state/fingerprint check. The book must still be marked complete
     or abandoned with a finish date: the server schema rejects anything
     else, and since Django Ninja validates the whole batch, one invalid
     book would 400 every book in the same push — so the plugin refuses
     client-side with a clear message instead.)
   - *Push all finished books* (full history scan, batched — also the backfill)
   - *Settings* (server URL, API key, toggles)
   - Plus a `Dispatcher:registerAction("ScriptoriumPush", ...)` so it's
     gesture-assignable.

2. **Periodic scan (the primary mechanism).** No cron on an ereader;
   "periodic" means: on every relevant lifecycle hook, run

   ```
   if now - last_attempt > 60 then scan_and_push() end
   ```

   Hooks: `onCloseDocument`, `onSuspend`, `onPowerOff`, `onReboot`,
   `onResume`, `onNetworkConnected`. The 60s debounce prevents races when
   hooks fire in bursts (close→suspend, resume→network-connect). Since
   unpushed finished books are rare, the scan is a cheap no-op almost every
   time: iterate reading history, skip entries whose sidecar mtime matches
   `scan_cache` (one `lfs.attributes` call each), open the few changed
   sidecars, and push any finished book not already covered by `pushed`.
   Network handling: if the scan finds work while offline, wrap the push in
   `NetworkMgr:runWhenOnline` — otherwise never touch WiFi.

3. **On finish (optional, off by default).** Instant push the moment a book
   is marked complete, for impatient moods. There is no status-change event
   in KOReader, so: snapshot `summary.status` in `onReaderReady`, re-check in
   `onEndOfBook` (deferred one UI tick, so the mark-as-finished dialog has
   resolved). Books it misses are caught by the scan at the latest on
   `onCloseDocument`, which is why this is cosmetic rather than load-bearing.

### 5.5 Idempotency & re-push (device side)

`pushed[md5] = {modified, fingerprint}` where `fingerprint` is a cheap hash of
the annotations (count + latest `datetime`/`datetime_updated`). A book is
(re-)pushed when it's finished **and** it's absent from `pushed`, or
(`modified` changed → new read), or (`fingerprint` changed → highlights
edited, server updates the blob). This is what makes "finish now, clean up
highlights tomorrow" work automatically.

Keying on the content-based partial MD5 means the state survives file moves
(§4.5).

### 5.6 Networking & failure handling

- All pushes wrapped in `NetworkMgr:runWhenOnline`; on failure (timeout,
  non-2xx) the book simply stays out of `pushed`, so the next scan retries it
  — a non-blocking `InfoMessage` reports the error.
- Batches are sent in **chunks of 5 books** so a backlog push stays below
  reverse-proxy body-size limits (nginx defaults to 1 MB and the scriptorium
  deployment doesn't raise it). A 413 splits the chunk in half and retries,
  down to single books; a single book that still 413s becomes a per-book
  error instead of a retry loop. Any other failure aborts the remaining
  chunks — those books stay pending for the next scan.
- `socketutil:set_timeout(...)` around requests (large-block timeouts for
  highlight-heavy payloads).
- Server `warnings` from the response are shown once per push in the
  confirmation message ("created new book → review queue" vs "matched
  existing").

---

## 6. API contract

The canonical definition lives with the server:
`../scriptorium/KOREADER.md` (and `/api/docs` once implemented). Summary of
what the plugin sends and gets back:

`POST <server_url>/api/koreader/sync/`, header
`Authorization: Bearer <api_key>`, one or several books per call:

```json
{
  "plugin_version": "1.0.0",
  "device": {"id": "kobo-clara-abc123", "model": "Kobo_clara2e"},
  "books": [
    {
      "md5": "8a1a4d0d64d09761b0eb0e3d97e4e848",
      "title": "The Left Hand of Darkness",
      "authors": ["Ursula K. Le Guin"],
      "language": "en",
      "series": "Hainish Cycle",
      "series_index": 6,
      "identifiers": ["ISBN:9780441478125", "calibre:1234", "uuid:..."],
      "pages": 304,
      "status": "complete",
      "rating": 5,
      "summary_note": "free-text note from KOReader, if any",
      "finished_on": "2026-07-01",
      "started_on": "2026-06-12",
      "total_time_seconds": 25440,
      "highlights": [
        {
          "text": "Light is the left hand of darkness...",
          "note": null,
          "chapter": "Chapter 16",
          "datetime": "2026-06-28 21:14:03",
          "pageno": 233,
          "color": "yellow",
          "drawer": "lighten"
        }
      ]
    }
  ]
}
```

Device-side payload rules:

- `authors`/`identifiers` are split on `\n` before sending;
  `finished_on` = `summary.modified`; `started_on`/`total_time_seconds` may
  be null (statistics plugin disabled).
- Plain page bookmarks (`drawer == nil`) are filtered out; position internals
  (`pos0/pos1/page` xpointers) are **not** sent — `pageno` + `chapter` +
  `datetime` keep highlights ordered and locatable.
- `status`: `"complete"` normally; `"abandoned"` only with the
  *push abandoned books* option (server records a did-not-finish read).

Response, per book:

```json
{
  "results": [
    {
      "md5": "8a1a4d0d64d09761b0eb0e3d97e4e848",
      "action": "created_book",          // matched | created_book | updated_read | error
      "book": "ursula-k-le-guin/the-left-hand-of-darkness",
      "read_id": 812,
      "highlights_stored": 14,
      "warnings": ["no ISBN found; matched by title/author"],
      "detail": null                     // error message when action == "error"
    }
  ]
}
```

Batch-level errors: `400` malformed payload, `401` bad token, `426` if
`plugin_version` is below the server's supported minimum.

---

## 7. Implementation plan

1. **Plugin MVP**: settings + manual "push this book" for the live reader.
   End-to-end validation on a real device against prod. (Requires the
   server-side endpoint, step 1 of the scriptorium-side plan.)
2. **Periodic scan**: history scan (new annotation format only), lifecycle
   hooks with the 60s debounce, "push all finished books" backfill for the
   existing backlog — this doubles as the one-time import of the historical
   KOReader backlog.
3. **Optional extras**: on-finish instant push (status snapshot/compare),
   push-abandoned option.
