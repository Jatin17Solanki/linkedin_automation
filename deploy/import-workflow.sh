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

echo "Checking for existing workflows..."

# List workflows and find ours by name
EXISTING=$(curl -s -H "X-N8N-API-KEY: $API_KEY" "$API_URL/workflows" | \
    python3 -c "
import sys, json
data = json.load(sys.stdin)
workflows = data.get('data', [])
for w in workflows:
    if 'job' in w.get('name', '').lower() and 'search' in w.get('name', '').lower():
        print(w['id'])
        break
" 2>/dev/null || echo "")

if [ -n "$EXISTING" ]; then
    echo "Found existing workflow (ID: $EXISTING). Updating..."
    RESPONSE=$(curl -s -w "\n%{http_code}" -X PUT \
        -H "X-N8N-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        -d @"$WORKFLOW_FILE" \
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

    # Activate the workflow
    echo "Activating workflow..."
    curl -s -X PATCH \
        -H "X-N8N-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        -d '{"active": true}' \
        "$API_URL/workflows/$EXISTING" > /dev/null

    echo "Workflow activated."
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

        # Activate
        if [ "$NEW_ID" != "unknown" ]; then
            curl -s -X PATCH \
                -H "X-N8N-API-KEY: $API_KEY" \
                -H "Content-Type: application/json" \
                -d '{"active": true}' \
                "$API_URL/workflows/$NEW_ID" > /dev/null
            echo "Workflow activated."
        fi
    else
        echo "ERROR: Failed to create workflow (HTTP $HTTP_CODE)"
        echo "$BODY"
        exit 1
    fi
fi

echo "Done."
