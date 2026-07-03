#!/bin/sh
# Deploy (or update) scriptorium.koplugin on the ereader over its Termux SSH.
# Usage: ./deploy.sh [host] [port]     (defaults: 192.168.178.108 8022)
#
# Copies into the KOReader *data* dir's plugins/ folder, which the plugin
# loader searches in addition to the install dir — so the plugin survives
# KOReader app updates. Plugin state (settings, pushed-books table) lives in
# KOReader's settings dir, not here, so redeploying never loses state.
set -eu
cd "$(dirname "$0")"

HOST="${1:-192.168.178.108}"
PORT="${2:-8022}"

run() { ssh -p "$PORT" "$HOST" "$1"; }

echo "Looking for the KOReader data dir on $HOST..."
KOREADER_DIR="$(run 'for d in /sdcard/koreader /storage/emulated/0/koreader; do if [ -d "$d" ]; then echo "$d"; break; fi; done')"
if [ -z "$KOREADER_DIR" ]; then
    echo "Could not find a KOReader data dir on the device — is this the right host?" >&2
    exit 1
fi
TARGET="$KOREADER_DIR/plugins/scriptorium.koplugin"
echo "Deploying to $TARGET"

# Stage next to the target, then swap, so a mid-transfer failure never
# leaves a half-copied plugin behind. Only ever touches our own plugin dir.
run "mkdir -p '$KOREADER_DIR/plugins' && rm -rf '$TARGET.staging'"
scp -P "$PORT" -q -r scriptorium.koplugin "$HOST:$TARGET.staging"
run "rm -rf '$TARGET' && mv '$TARGET.staging' '$TARGET'"

echo "Done. Restart KOReader on the device to load the new version."
