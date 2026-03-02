#!/bin/bash
set -euo pipefail

# One-time setup script for GCP e2-micro VM
# Run as: sudo bash setup.sh

echo "=== n8n Production Setup ==="

# Install Docker if not present
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$SUDO_USER"
    echo "Docker installed. You may need to log out and back in for group changes."
fi

# Install Docker Compose plugin if not present
if ! docker compose version &> /dev/null; then
    echo "Installing Docker Compose plugin..."
    sudo apt-get update
    sudo apt-get install -y docker-compose-plugin
fi

# Get VM external IP
VM_IP=$(curl -s http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip -H "Metadata-Flavor: Google" 2>/dev/null || curl -s ifconfig.me)

echo "Detected VM IP: $VM_IP"

# Create deployment directory
DEPLOY_DIR="/opt/n8n"
mkdir -p "$DEPLOY_DIR"

# Copy files
cp docker-compose.prod.yml "$DEPLOY_DIR/docker-compose.yml"

# Write Caddyfile with actual IP substituted
sed "s/\${VM_IP}/$VM_IP/g" Caddyfile > "$DEPLOY_DIR/Caddyfile"

# Create .env file
ENV_FILE="$DEPLOY_DIR/.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Creating .env file..."
    read -rp "Enter n8n basic auth username: " N8N_USER
    read -rsp "Enter n8n basic auth password: " N8N_PASS
    echo
    cat > "$ENV_FILE" <<EOF
VM_IP=$VM_IP
N8N_BASIC_AUTH_USER=$N8N_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_PASS
EOF
    chmod 600 "$ENV_FILE"
    echo ".env file created at $ENV_FILE"
else
    # Update VM_IP in existing .env
    sed -i "s/^VM_IP=.*/VM_IP=$VM_IP/" "$ENV_FILE"
    echo "Updated VM_IP in existing .env"
fi

# Open firewall ports (GCP uses iptables by default on Ubuntu)
echo "Ensuring ports 80 and 443 are open..."
sudo iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || sudo iptables -A INPUT -p tcp --dport 80 -j ACCEPT
sudo iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || sudo iptables -A INPUT -p tcp --dport 443 -j ACCEPT

# Start services
echo "Starting n8n and Caddy..."
cd "$DEPLOY_DIR"
docker compose up -d

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
