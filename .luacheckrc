-- Based on KOReader's own .luacheckrc (the plugin runs inside KOReader).
unused_args = false
std = "luajit"
-- ignore implicit self
self = false

globals = {
    "G_reader_settings",
    "G_defaults",
}

ignore = {
    "631", -- line is too long
}
