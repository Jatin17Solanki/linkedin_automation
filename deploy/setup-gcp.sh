#!/bin/bash
set -euo pipefail

# One-time setup script for a GCP e2-micro VM.
# Run from repo root: sudo bash deploy/setup-gcp.sh
#
# Provider-agnostic logic (Docker install, volumes, swapfile, .env, firewall,
# compose up) lives in setup-common.sh -- this script only handles what's
# actually GCP-specific: IP autodetection via the metadata server, and the
# GCP-flavored next-steps printout. See setup-aws.sh for the EC2 equivalent.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./setup-common.sh
source "$SCRIPT_DIR/setup-common.sh"

echo "=== n8n Production Setup (GCP) ==="

# Get VM external IP from the GCP metadata server, falling back to a public
# IP-echo service if that's unreachable (e.g. running this outside GCP).
VM_IP=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google" 2>/dev/null || curl -s ifconfig.me)

echo "Detected VM IP: $VM_IP"

install_docker
stage_deploy_files
setup_swapfile
create_docker_volumes
create_env_file
open_firewall_ports
start_stack

echo ""
echo "=== Setup Complete ==="
echo "n8n is running at: https://$VM_IP.nip.io"
echo ""
echo "Next steps:"
echo "  1. Make sure 'Allow HTTP' and 'Allow HTTPS' are checked on your VM in GCP Console"
echo "  2. Open https://$VM_IP.nip.io in your browser"
echo "  3. Set up credentials (Google Sheets, Telegram) in n8n UI"
echo "  4. Import the workflow and enable Telegram Trigger"
echo "  5. Generate an API key in n8n Settings > API for CI/CD"
