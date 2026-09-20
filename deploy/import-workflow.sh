#!/bin/bash
set -euo pipefail

# Imports/updates the n8n workflow via the REST API
# Usage: bash import-workflow.sh <workflow-json-path> <n8n-base-url> <api-key>

WORKFLOW_FILE="${1:?Usage: import-workflow.sh <json-file> <n8n-url> <api-key>}"
N8N_URL="${2:?Missing n8n base URL}"
API_KEY="${3:?Missing n8n API key}"

if [ ! -f "$WORKFLOW_FILE" ]; then
    echo "ERROR: Workflow file not found: $WORKFLOW_FILE"
    exit 1
fi

API_URL="${N8N_URL}/api/v1"

# Match against the workflow's own "name" field from the JSON file, not a
# hardcoded substring -- this lets the same script import any of the 3
# workflow JSONs (LinkedIn Job Search V1 / Company Search V1 / Job Parser)
# without per-workflow special-casing. Passed via env var (not interpolated
# into the python source) to avoid any quoting issues.
export WORKFLOW_FILE
WORKFLOW_NAME=$(python3 -c "import json, os; print(json.load(open(os.environ['WORKFLOW_FILE'], encoding='utf-8'))['name'])")

echo "Checking for existing workflow named '$WORKFLOW_NAME'..."

# List workflows and find ours by exact name match
export WORKFLOW_NAME
EXISTING=$(curl -s -H "X-N8N-API-KEY: $API_KEY" "$API_URL/workflows" | \
    python3 -c "
import sys, json, os
data = json.load(sys.stdin)
workflows = data.get('data', [])
target = os.environ['WORKFLOW_NAME']
for w in workflows:
    if w.get('name', '') == target:
        print(w['id'])
        break
" 2>/dev/null || echo "")

if [ -n "$EXISTING" ]; then
    echo "Found existing workflow (ID: $EXISTING). Updating..."

    # The shipped JSON is a sanitized template (placeholder credentials and spreadsheet). Carry the
    # instance's own wiring over so an update does not reset it (see merge-workflow.py for exactly what).
    # PRESERVE_WIRING=false imports the file exactly as shipped. DRY_RUN=true only writes the merged
    # payload to $DRY_RUN_OUT (default merged-preview.json) and changes nothing on the instance.
    PAYLOAD="$WORKFLOW_FILE"
    if [ "${PRESERVE_WIRING:-true}" = "true" ]; then
        TMP_DIR=$(mktemp -d)
        curl -s -H "X-N8N-API-KEY: $API_KEY" "$API_URL/workflows/$EXISTING" > "$TMP_DIR/live.json"
        if python3 "$(dirname "$0")/merge-workflow.py" "$TMP_DIR/live.json" "$WORKFLOW_FILE" "$TMP_DIR/merged.json"; then
            PAYLOAD="$TMP_DIR/merged.json"
        else
            echo "WARNING: could not merge the instance's wiring; importing the file as shipped (credentials and spreadsheet will need re-selecting)."
        fi
    fi
    if [ "${DRY_RUN:-false}" = "true" ]; then
        echo "DRY_RUN: would PUT $PAYLOAD to $API_URL/workflows/$EXISTING"
        if [ "$PAYLOAD" != "$WORKFLOW_FILE" ]; then cp "$PAYLOAD" "${DRY_RUN_OUT:-merged-preview.json}"; fi
        exit 0
    fi

    RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
        -H "X-N8N-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$PAYLOAD" \
        "$API_URL/workflows/$EXISTING")
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        echo "Workflow updated successfully."
    else
        echo "ERROR: Failed to update workflow (HTTP $HTTP_CODE)"
        echo "$BODY"
        exit 1
    fi

    # Activate the workflow (n8n public API: POST /workflows/{id}/activate)
    echo "Activating workflow..."
    ACT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "X-N8N-API-KEY: $API_KEY" "$API_URL/workflows/$EXISTING/activate")
    if [ "$ACT_CODE" -ge 200 ] && [ "$ACT_CODE" -lt 300 ]; then
        echo "Workflow activated."
    else
        echo "NOTE: activation returned HTTP $ACT_CODE - open the workflow in n8n and check its Active toggle (a workflow with an unattached credential cannot activate)."
    fi
else
    echo "No existing workflow found. Creating new..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X POST \
        -H "X-N8N-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$WORKFLOW_FILE" \
        "$API_URL/workflows")
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        NEW_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "unknown")
        echo "Workflow created (ID: $NEW_ID)."

        # Activate (n8n public API: POST /workflows/{id}/activate). A brand-new import has placeholder
        # credentials, so activation is expected to be refused until they are attached in the editor.
        if [ "$NEW_ID" != "unknown" ]; then
            ACT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "X-N8N-API-KEY: $API_KEY" "$API_URL/workflows/$NEW_ID/activate")
            if [ "$ACT_CODE" -ge 200 ] && [ "$ACT_CODE" -lt 300 ]; then
                echo "Workflow activated."
            else
                echo "NOTE: not activated (HTTP $ACT_CODE) - attach its credentials in n8n, then toggle Active."
            fi
        fi
    else
        echo "ERROR: Failed to create workflow (HTTP $HTTP_CODE)"
        echo "$BODY"
        exit 1
    fi
fi

echo "Done."
