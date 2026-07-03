[private]
default:
    just --list

# Deploy (or update) the plugin on the ereader over Termux SSH.
deploy host="192.168.178.108" port="8022":
    ./deploy.sh {{host}} {{port}}

# Run the stub-based test suites (plain luajit, no KOReader needed).
test:
    luajit tests/test_collect.lua
    luajit tests/test_main.lua

# Lint the plugin (requires luacheck).
lint:
    luacheck scriptorium.koplugin
