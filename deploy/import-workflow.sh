#!/bin/bash
set -euo pipefail

# Imports/updates an n8n workflow via the REST API, keeping the instance's own wiring (see merge-workflow.py).
# Usage: bash import-workflow.sh <workflow-json-path> <n8n-base-url> <api-key>
#
# Optional environment variables:
#   PRESERVE_WIRING=false    import the file exactly as shipped (credentials / spreadsheet selections reset)
#   DRY_RUN=true             write the merged payload to $DRY_RUN_OUT (default merged-preview.json); change nothing
#   CREATE_IF_MISSING=true   create the workflow when none with this name exists (default: stop and say so)

WORKFLOW_FILE="${1:?Usage: import-workflow.sh <json-file> <n8n-url> <api-key>}"
N8N_URL="${2:?Missing n8n base URL}"
API_KEY="${3:?Missing n8n API key}"

fail() { echo "ERROR: $*" >&2; exit 1; }

[ -f "$WORKFLOW_FILE" ] || fail "Workflow file not found: $WORKFLOW_FILE"

API_URL="${N8N_URL%/}/api/v1"

# Match against the workflow's own "name" field from the JSON file, not a hardcoded substring -- this lets the
# same script import any of the 3 workflow JSONs (LinkedIn Job Search V1 / Company Search V1 / Job Parser) without
# per-workflow special-casing. Passed via env var (not interpolated into the python source) to avoid quoting issues.
export WORKFLOW_FILE
WORKFLOW_NAME=$(python3 -c "import json, os; print(json.load(open(os.environ['WORKFLOW_FILE'], encoding='utf-8'))['name'])")
export WORKFLOW_NAME

echo "Checking for existing workflow named '$WORKFLOW_NAME'..."

# List the workflows. A FAILED listing must never be mistaken for "not found": that used to fall through to creating
# a duplicate workflow while hiding the real problem (e.g. n8n unreachable).
LIST_RESPONSE=$(curl -sS -w "\n%{http_code}" -H "X-N8N-API-KEY: $API_KEY" "$API_URL/workflows?limit=250") || \
    fail "Could not reach n8n at $N8N_URL (curl's message is above). Check the address (https://<VM_IP>.nip.io), that n8n is running, and that this machine can reach it. Nothing was changed."
LIST_CODE=$(echo "$LIST_RESPONSE" | tail -1)
LIST_BODY=$(echo "$LIST_RESPONSE" | sed '$d')
case "$LIST_CODE" in
    2??) ;;
    401) fail "n8n refused the API key (HTTP 401). Create one in n8n under Settings > API and pass it as the third argument. Nothing was changed." ;;
    *)   fail "Listing workflows failed (HTTP $LIST_CODE): $(echo "$LIST_BODY" | head -c 300). Nothing was changed." ;;
esac

export LIST_BODY
PARSED=$(python3 -c "
import json, os
wfs = json.loads(os.environ['LIST_BODY']).get('data', [])
target = os.environ['WORKFLOW_NAME']
print(next((w['id'] for w in wfs if w.get('name', '') == target), ''))
for w in wfs:
    print(w.get('name', ''))
") || fail "Unexpected reply from n8n (not a workflow list): $(echo "$LIST_BODY" | head -c 300). Nothing was changed."
EXISTING=$(echo "$PARSED" | head -1)

if [ -n "$EXISTING" ]; then
    echo "Found existing workflow (ID: $EXISTING). Updating..."

    # The shipped JSON is a sanitized template (placeholder credentials and spreadsheet). Carry the instance's own
    # wiring over so an update does not reset it (see merge-workflow.py for exactly what).
    PAYLOAD="$WORKFLOW_FILE"
    if [ "${PRESERVE_WIRING:-true}" = "true" ]; then
        TMP_DIR=$(mktemp -d)
        LIVE_CODE=$(curl -sS -o "$TMP_DIR/live.json" -w "%{http_code}" -H "X-N8N-API-KEY: $API_KEY" "$API_URL/workflows/$EXISTING") || \
            fail "Could not read the live workflow from n8n. Nothing was changed."
        [ "$LIVE_CODE" = "200" ] || fail "Could not read the live workflow (HTTP $LIVE_CODE). Nothing was changed."
        python3 "$(dirname "$0")/merge-workflow.py" "$TMP_DIR/live.json" "$WORKFLOW_FILE" "$TMP_DIR/merged.json" || \
            fail "Could not merge the instance's wiring. Nothing was changed. Re-run with PRESERVE_WIRING=false to import the file exactly as shipped (you would then re-attach credentials and re-pick the spreadsheet)."
        PAYLOAD="$TMP_DIR/merged.json"
    fi
    if [ "${DRY_RUN:-false}" = "true" ]; then
        echo "DRY_RUN: would PUT $PAYLOAD to $API_URL/workflows/$EXISTING"
        if [ "$PAYLOAD" != "$WORKFLOW_FILE" ]; then cp "$PAYLOAD" "${DRY_RUN_OUT:-merged-preview.json}"; fi
        exit 0
    fi

    RESPONSE=$(curl -sS -w "\n%{http_code}" -X PUT \
        -H "X-N8N-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$PAYLOAD" \
        "$API_URL/workflows/$EXISTING") || fail "Could not reach n8n while updating the workflow."
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        echo "Workflow updated successfully."
    else
        fail "Failed to update workflow (HTTP $HTTP_CODE): $BODY"
    fi

    # Activate the workflow (n8n public API: POST /workflows/{id}/activate)
    echo "Activating workflow..."
    ACT_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST -H "X-N8N-API-KEY: $API_KEY" "$API_URL/workflows/$EXISTING/activate") || ACT_CODE="000"
    if [ "$ACT_CODE" -ge 200 ] && [ "$ACT_CODE" -lt 300 ]; then
        echo "Workflow activated."
    else
        echo "NOTE: activation returned HTTP $ACT_CODE - open the workflow in n8n and check its Active toggle (a workflow with an unattached credential cannot activate)."
    fi
else
    if [ "${CREATE_IF_MISSING:-false}" != "true" ]; then
        echo "ERROR: no workflow named '$WORKFLOW_NAME' exists on this n8n, so there is nothing to update. Nothing was changed." >&2
        echo "Workflows found on this instance:" >&2
        echo "$PARSED" | tail -n +2 | sed 's/^/  - /' >&2
        echo "If you renamed the workflow, rename it back to exactly '$WORKFLOW_NAME'. To create it as a new workflow instead, re-run with CREATE_IF_MISSING=true." >&2
        exit 1
    fi

    echo "No existing workflow found. Creating new (CREATE_IF_MISSING=true)..."
    RESPONSE=$(curl -sS -w "\n%{http_code}" -X POST \
        -H "X-N8N-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$WORKFLOW_FILE" \
        "$API_URL/workflows") || fail "Could not reach n8n while creating the workflow."
    HTTP_CODE=$(echo "$RESPONSE" | tail -1)
    BODY=$(echo "$RESPONSE" | sed '$d')

    if [ "$HTTP_CODE" -ge 200 ] && [ "$HTTP_CODE" -lt 300 ]; then
        NEW_ID=$(echo "$BODY" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || echo "unknown")
        echo "Workflow created (ID: $NEW_ID)."

        # Activate (n8n public API: POST /workflows/{id}/activate). A brand-new import has placeholder
        # credentials, so activation is expected to be refused until they are attached in the editor.
        if [ "$NEW_ID" != "unknown" ]; then
            ACT_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -X POST -H "X-N8N-API-KEY: $API_KEY" "$API_URL/workflows/$NEW_ID/activate") || ACT_CODE="000"
            if [ "$ACT_CODE" -ge 200 ] && [ "$ACT_CODE" -lt 300 ]; then
                echo "Workflow activated."
            else
                echo "NOTE: not activated (HTTP $ACT_CODE) - attach its credentials in n8n, then toggle Active."
            fi
        fi
    else
        fail "Failed to create workflow (HTTP $HTTP_CODE): $BODY"
    fi
fi

echo "Done."
