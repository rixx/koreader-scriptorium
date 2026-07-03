[private]
default:
    just --list

# Run the stub-based test suites (plain luajit, no KOReader needed).
test:
    luajit tests/test_collect.lua
    luajit tests/test_main.lua

# Format the Lua sources in place (requires stylua).
fmt:
    stylua scriptorium.koplugin tests

# CI checks: formatting (stylua --check) and linting (luacheck).
check:
    stylua --check scriptorium.koplugin tests
    luacheck scriptorium.koplugin

# Push main and publish a GitHub release for the version in _meta.lua.
release:
    #!/usr/bin/env bash
    set -euo pipefail
    version=$(sed -n 's/.*version = "\([0-9.]*\)".*/\1/p' scriptorium.koplugin/_meta.lua)
    if [ -z "$version" ]; then
        echo "could not parse version from scriptorium.koplugin/_meta.lua" >&2
        exit 1
    fi
    tag="v$version"
    if gh release view "$tag" --json name > /dev/null 2>&1; then
        echo "release $tag already exists — bump the version in scriptorium.koplugin/_meta.lua first" >&2
        exit 1
    fi
    git push origin main
    gh release create "$tag" --title "$tag" --generate-notes

