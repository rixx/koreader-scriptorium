# Tests

Stub-based smoke tests that run with plain `luajit` from the repo root — no
KOReader checkout needed (all KOReader modules are stubbed via
`package.preload`):

```sh
luajit tests/test_collect.lua   # payload building, filtering, schema guards
luajit tests/test_main.lua      # scan, push, idempotency, retry, debounce
```

They must be run from the repo root (they add `scriptorium.koplugin/?.lua`
to `package.path` relatively).

These complement, not replace, a real test in the KOReader emulator: symlink
`scriptorium.koplugin/` into a `koreader/koreader` checkout's `plugins/` dir
and `./kodev run`.
