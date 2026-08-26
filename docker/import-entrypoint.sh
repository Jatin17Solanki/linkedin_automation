#!/bin/sh
# Imports the bundled workflow JSONs into n8n on first container start, then
# hands off to the base image's own entrypoint. Uses a marker file inside the
# persistent n8n data volume so restarts don't re-import (or duplicate) the
# workflows once they've been imported once.
set -e

MARKER="/home/node/.n8n/.workflows-imported"

if [ ! -f "$MARKER" ]; then
    echo "[import] Importing bundled workflows..."
    for f in /workflows/*.json; do
        echo "[import]   $f"
        n8n import:workflow --input="$f"
    done
    mkdir -p "$(dirname "$MARKER")"
    touch "$MARKER"
    echo "[import] Done. Workflow definitions imported — credentials (Google Sheets, Telegram, Gmail) still need one-time setup in the n8n UI."
else
    echo "[import] Workflows already imported (marker found), skipping."
fi

exec /docker-entrypoint.sh "$@"
