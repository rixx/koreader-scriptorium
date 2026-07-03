local _ = require("gettext")
return {
    name = "scriptorium",
    version = "1.0.1", -- keep in sync with Api.VERSION (tests enforce this)
    fullname = _("Scriptorium"),
    description = _([[Pushes finished books — metadata, finished date, reading time, and all highlights — to a scriptorium instance (books.rixx.de).]]),
}
