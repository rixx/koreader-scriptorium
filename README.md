# koreader-scriptorium

A [KOReader](https://github.com/koreader/koreader) plugin that pushes finished
books — metadata, finished date, aggregate reading time, and all highlights —
to [scriptorium](https://books.rixx.de), where they land in the review queue.
Highlights become the raw material for published quotes and plot summaries.

**Status: spec phase.** See [SPEC.md](SPEC.md) for the full plugin design; the
server side lives in the scriptorium repo (`KOREADER.md` there).

## How it will work

- Mark a book as finished in KOReader; the plugin picks it up on the next
  lifecycle hook (close/suspend/wake/network) and pushes it — or push manually
  from the Tools menu.
- Books unknown to scriptorium are auto-created in the to-review queue.
- Pushes are idempotent: edit your highlights after finishing and the next
  scan updates the server copy.

## Requirements

- KOReader ≥ v2024.07 (the `annotations` sidecar format)
- A scriptorium instance with the `/api/koreader/sync` endpoint and an API key

## Installation (once it exists)

Copy `scriptorium.koplugin/` into `koreader/plugins/` on the device, restart
KOReader, then set the server URL and API key in Tools → Scriptorium →
Settings.
