#!/bin/bash
set -euo pipefail

# One-time setup script for an AWS EC2 free-tier VM (t2.micro/t3.micro).
# Run from repo root: sudo bash deploy/setup-aws.sh
#
# Provider-agnostic logic (Docker install, volumes, swapfile, .env, firewall,
# compose up) lives in setup-common.sh -- this script only handles what's
# actually AWS-specific: IP autodetection via IMDSv2, and the AWS-flavored
# next-steps printout (including the EC2 Security Group reminder -- iptables
# alone is NOT sufficient on AWS, unlike GCP). See setup-gcp.sh for the GCP
# equivalent.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./setup-common.sh
source "$SCRIPT_DIR/setup-common.sh"

echo "=== n8n Production Setup (AWS) ==="

# Get VM public IP via EC2's Instance Metadata Service v2 (IMDSv2). Unlike
# v1 (a plain GET), v2 requires a short-lived session token first -- AWS
# disables v1 by default on newer instances, so this is the only reliable
# path. Falls back to a public IP-echo service if the metadata endpoint is
# unreachable (e.g. running this outside EC2).
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo "")
if [ -n "$IMDS_TOKEN" ]; then
    VM_IP=$(curl -s -H "X-aws-ec2-metadata-token: $IMDS_TOKEN" http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "")
fi
VM_IP="${VM_IP:-$(curl -s ifconfig.me)}"

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
echo "  1. IMPORTANT: iptables rules alone are not enough on AWS -- open ports 80"
echo "     and 443 (inbound, source 0.0.0.0/0) in your EC2 instance's Security"
echo "     Group too, or nothing outside the VM can reach it. See SETUP_GUIDE.md."
echo "  2. Open https://$VM_IP.nip.io in your browser and log in"
echo "  3. Follow SETUP_GUIDE.md Part 3: create the Google Sheets + Telegram credentials,"
echo "     connect them to the nodes (the workflows are already imported), enable the"
echo "     Telegram Trigger, then toggle the workflow Active"
echo "  (Optional) CI/CD: SETUP_GUIDE.md section 6.1 -- only needed if you edit the workflows in a fork"
