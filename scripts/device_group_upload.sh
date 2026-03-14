#!/bin/bash
# =============================================================================
# Upload Device Group Mappings to Axiom
#
# Reads groups/device_groups.json and ships it to the Axiom devices dataset
# so dashboard queries can join on MAC to resolve device groups.
#
# This merges group data with the live Redis device inventory (IP, MAC, name)
# so Axiom has a single lookup dataset with: IP, MAC, name, AND group.
#
# Install location: /home/pi/.firewalla/config/device_group_upload.sh
# Run: manually after editing device_groups.json, or via cron
# =============================================================================

set -euo pipefail

CONFIG_DIR="/home/pi/.firewalla/config"
ENV_FILE="${CONFIG_DIR}/log_shipping.env"
GROUP_FILE="${CONFIG_DIR}/device_groups.json"
TMPFILE="/tmp/device_groups_enriched.json"

# --- Load environment variables ----------------------------------------------
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

LOOKUP_DATASET="${AXIOM_LOOKUP_DATASET:-${AXIOM_DATASET}-devices}"

if [ -z "${AXIOM_API_TOKEN:-}" ]; then
    echo "[group-upload] ERROR: AXIOM_API_TOKEN not set"
    exit 1
fi

if [ ! -f "$GROUP_FILE" ]; then
    echo "[group-upload] ERROR: $GROUP_FILE not found"
    echo "[group-upload] Copy device_groups.json to $CONFIG_DIR"
    exit 1
fi

# --- Merge group data with live Redis inventory ------------------------------
# For each device in the group file, look up its current IP from Redis
# so the group mapping stays accurate even when IPs change via DHCP.

TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "[" > "$TMPFILE"
FIRST=true

# Parse the JSON file with simple grep/sed (no jq dependency on Firewalla)
# Extract mac and group fields from each line
grep '"mac"' "$GROUP_FILE" | while IFS= read -r line; do
    MAC=$(echo "$line" | sed 's/.*"mac": *"\([^"]*\)".*/\1/')
    GROUP=$(echo "$line" | sed 's/.*"group": *"\([^"]*\)".*/\1/')
    GNAME=$(echo "$line" | sed 's/.*"name": *"\([^"]*\)".*/\1/')

    # Look up current IP from Redis using MAC
    REDIS_KEY="host:mac:${MAC}"
    IPV4=$(redis-cli hget "$REDIS_KEY" "ipv4Addr" 2>/dev/null || true)
    BNAME=$(redis-cli hget "$REDIS_KEY" "bname" 2>/dev/null || true)

    [ -z "$IPV4" ] && continue

    # Use Redis bname if available (most current), fall back to group file name
    DISPLAY_NAME="${BNAME:-${GNAME}}"
    DISPLAY_NAME=$(echo "$DISPLAY_NAME" | tr -cd '[:alnum:] ._-')
    GROUP=$(echo "$GROUP" | tr -cd '[:alnum:] ._-')

    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        echo "," >> "$TMPFILE"
    fi

    cat >> "$TMPFILE" <<EOF
{"_time":"${TIMESTAMP}","record_type":"device_lookup","ipv4":"${IPV4}","mac":"${MAC}","name":"${DISPLAY_NAME}","group":"${GROUP}"}
EOF
done

echo "]" >> "$TMPFILE"

# --- Check if we got any records ---------------------------------------------
RECORD_COUNT=$(grep -c '"record_type"' "$TMPFILE" 2>/dev/null || echo 0)
if [ "$RECORD_COUNT" -eq 0 ]; then
    echo "[group-upload] ERROR: No records generated. Check $GROUP_FILE format."
    rm -f "$TMPFILE"
    exit 1
fi

# --- Ship to Axiom -----------------------------------------------------------
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" \
    -X POST "https://api.axiom.co/v1/datasets/${LOOKUP_DATASET}/ingest" \
    -H "Authorization: Bearer ${AXIOM_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data-binary @"$TMPFILE" \
    --compressed)

HTTP_BODY=$(echo "$HTTP_RESPONSE" | head -n -1)
HTTP_CODE=$(echo "$HTTP_RESPONSE" | tail -n 1)

if [ "$HTTP_CODE" = "200" ]; then
    echo "[group-upload] Exported ${RECORD_COUNT} devices with groups to ${LOOKUP_DATASET}"
else
    echo "[group-upload] ERROR: HTTP ${HTTP_CODE}"
    echo "[group-upload] Response: ${HTTP_BODY}"
fi

rm -f "$TMPFILE"
