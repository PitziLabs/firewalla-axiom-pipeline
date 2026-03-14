#!/bin/bash
# =============================================================================
# Deploy firewalla-axiom-pipeline to a Firewalla Gold SE
#
# Usage:
#   ./deploy.sh <firewalla-ip>
#   ./deploy.sh 192.168.1.1
#
# Copies all config files to the Firewalla's persistent directory,
# sets permissions, starts the pipeline, and installs cron.
#
# Prerequisites:
#   - SSH access to the Firewalla (pi user)
#   - .env file configured with your Axiom credentials
#   - Docker enabled on the Firewalla
# =============================================================================

set -euo pipefail

if [ -z "${1:-}" ]; then
    echo "Usage: ./deploy.sh <firewalla-ip>"
    echo "  e.g. ./deploy.sh 192.168.1.1"
    exit 1
fi

FW_IP="$1"
FW_USER="pi"
FW_CONFIG="/home/pi/.firewalla/config"

# --- Preflight checks --------------------------------------------------------
if [ ! -f ".env" ]; then
    echo "ERROR: .env file not found. Copy env.example to .env and configure it."
    exit 1
fi

echo "=== Deploying firewalla-axiom-pipeline to ${FW_IP} ==="

# --- Ensure remote directories exist -----------------------------------------
echo "[1/5] Creating directories on Firewalla..."
ssh ${FW_USER}@${FW_IP} "mkdir -p ${FW_CONFIG}/post_main.d ${FW_CONFIG}/fluent-bit-data"

# --- Copy files --------------------------------------------------------------
echo "[2/5] Copying config files..."
scp fluent-bit/fluent-bit.conf ${FW_USER}@${FW_IP}:${FW_CONFIG}/fluent-bit.conf
scp fluent-bit/parsers.conf ${FW_USER}@${FW_IP}:${FW_CONFIG}/parsers.conf
scp scripts/device_lookup_export.sh ${FW_USER}@${FW_IP}:${FW_CONFIG}/device_lookup_export.sh
scp scripts/start_log_shipping.sh ${FW_USER}@${FW_IP}:${FW_CONFIG}/post_main.d/start_log_shipping.sh
scp cron/user_crontab ${FW_USER}@${FW_IP}:${FW_CONFIG}/user_crontab
scp .env ${FW_USER}@${FW_IP}:${FW_CONFIG}/log_shipping.env

# --- Set permissions ---------------------------------------------------------
echo "[3/5] Setting permissions..."
ssh ${FW_USER}@${FW_IP} "chmod +x ${FW_CONFIG}/post_main.d/start_log_shipping.sh ${FW_CONFIG}/device_lookup_export.sh"

# --- Start the pipeline ------------------------------------------------------
echo "[4/5] Starting Fluent Bit pipeline..."
ssh ${FW_USER}@${FW_IP} "sudo ${FW_CONFIG}/post_main.d/start_log_shipping.sh"

# --- Install cron and run initial device export ------------------------------
echo "[5/5] Installing cron and exporting device inventory..."
ssh ${FW_USER}@${FW_IP} "crontab ${FW_CONFIG}/user_crontab && sudo ${FW_CONFIG}/device_lookup_export.sh"

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Verify:"
echo "  ssh ${FW_USER}@${FW_IP} 'sudo docker logs --tail 10 fluent-bit-axiom'"
echo ""
echo "Then check Axiom Stream view for incoming events."
