local _ = require("gettext")
return {
    name = "scriptorium",
    version = "1.0.1", -- single source of truth; Api.VERSION loads from here
    fullname = _("Scriptorium"),
    description = _([[Pushes finished books — metadata, finished date, reading time, and all highlights — to a scriptorium instance (books.rixx.de).]]),
}
