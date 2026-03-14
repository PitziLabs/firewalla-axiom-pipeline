#!/bin/bash
# =============================================================================
# Firewalla Device Lookup Exporter
#
# Reads device inventory from Redis (host:mac:* keys), extracts IP-to-name
# mappings, and ships them to Axiom as a lookup dataset. Run hourly via cron.
#
# Install location: /home/pi/.firewalla/config/device_lookup_export.sh
# =============================================================================

set -euo pipefail

CONFIG_DIR="/home/pi/.firewalla/config"
ENV_FILE="${CONFIG_DIR}/log_shipping.env"
TMPFILE="/tmp/device_lookup.json"

# --- Load environment variables ----------------------------------------------
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
fi

LOOKUP_DATASET="${AXIOM_LOOKUP_DATASET:-${AXIOM_DATASET}-devices}"

if [ -z "${AXIOM_API_TOKEN:-}" ]; then
    echo "[device-lookup] ERROR: AXIOM_API_TOKEN not set"
    exit 1
fi

# --- Extract device mappings from Redis --------------------------------------
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "[" > "$TMPFILE"
FIRST=true

for key in $(redis-cli keys "host:mac:*" 2>/dev/null); do
    IPV4=$(redis-cli hget "$key" "ipv4Addr" 2>/dev/null || true)
    BNAME=$(redis-cli hget "$key" "bname" 2>/dev/null || true)
    MAC=$(redis-cli hget "$key" "mac" 2>/dev/null || true)
    DHCP_NAME=$(redis-cli hget "$key" "dhcpName" 2>/dev/null || true)
    INTF_PORT=$(redis-cli hget "$key" "stpPort" 2>/dev/null || true)

    # Skip entries with no IP
    [ -z "$IPV4" ] && continue

    # Use bname → dhcpName → MAC as fallback chain
    NAME="${BNAME:-${DHCP_NAME:-${MAC:-unknown}}}"

    # Sanitize: keep only safe characters for JSON
    NAME=$(echo "$NAME" | tr -cd '[:alnum:] ._-')

    if [ "$FIRST" = true ]; then
        FIRST=false
    else
        echo "," >> "$TMPFILE"
    fi

    cat >> "$TMPFILE" <<EOF
{"_time":"${TIMESTAMP}","record_type":"device_lookup","ipv4":"${IPV4}","name":"${NAME}","mac":"${MAC}","interface":"${INTF_PORT}"}
EOF

done

echo "]" >> "$TMPFILE"

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
    DEVICE_COUNT=$(grep -c '"record_type"' "$TMPFILE" || echo 0)
    echo "[device-lookup] Exported ${DEVICE_COUNT} devices to ${LOOKUP_DATASET}"
else
    echo "[device-lookup] ERROR: HTTP ${HTTP_CODE}"
    echo "[device-lookup] Response: ${HTTP_BODY}"
fi

rm -f "$TMPFILE"
