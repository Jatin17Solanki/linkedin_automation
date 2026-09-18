#!/bin/bash
# Shared setup logic for cloud deploy scripts (setup-gcp.sh, setup-aws.sh).
# Not meant to be run directly -- sourced by a provider-specific script that
# defines VM_IP and SCRIPT_DIR first, then calls these functions in order.
#
# Every function here is provider-agnostic (Docker install, deploy dir, swap,
# volumes, .env, firewall via iptables, compose up). Provider-specific bits
# (IP autodetection, cloud firewall/security-group config, walkthrough text)
# stay in the caller.

set -euo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/opt/n8n}"

install_docker() {
    if ! command -v docker &> /dev/null; then
        echo "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        usermod -aG docker "${SUDO_USER:-$(whoami)}"
        echo "Docker installed. You may need to log out and back in for group changes."
    fi

    if ! docker compose version &> /dev/null; then
        echo "Installing Docker Compose plugin..."
        apt-get update
        apt-get install -y docker-compose-plugin
    fi
}

# Copies the compose file + Caddyfile into $DEPLOY_DIR, substituting VM_IP
# into the Caddyfile. Requires $SCRIPT_DIR and $VM_IP to be set by the caller.
stage_deploy_files() {
    mkdir -p "$DEPLOY_DIR"
    cp "$SCRIPT_DIR/docker-compose.prod.yml" "$DEPLOY_DIR/docker-compose.yml"
    sed "s/PLACEHOLDER_VM_IP/$VM_IP/g" "$SCRIPT_DIR/Caddyfile" > "$DEPLOY_DIR/Caddyfile"
}

# Creates the 3 external Docker volumes docker-compose.prod.yml expects to
# already exist. Idempotent -- `docker volume create` on an existing volume
# is a no-op, not an error.
create_docker_volumes() {
    echo "Ensuring Docker volumes exist..."
    docker volume create n8n_n8n_data > /dev/null
    docker volume create n8n_caddy_data > /dev/null
    docker volume create n8n_caddy_config > /dev/null
}

# 2GB swapfile -- required on 1GB-RAM free-tier instances (e2-micro, t2/t3.micro)
# so a memory-heavy workflow run degrades to slow-but-alive instead of an OOM
# freeze of the whole VM (see TROUBLESHOOTING.md). Gated behind LOW_MEMORY
# (default true) since it's only needed on these small instance types --
# set LOW_MEMORY=false to skip on a larger VM.
setup_swapfile() {
    if [ "${LOW_MEMORY:-true}" != "true" ]; then
        echo "LOW_MEMORY=false -- skipping swapfile setup."
        return
    fi

    if swapon --show | grep -q .; then
        echo "Swap already active, skipping swapfile setup."
        return
    fi

    echo "Setting up 2GB swapfile (LOW_MEMORY=true)..."
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    grep -q '^vm.swappiness=' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl -p > /dev/null
}

# Creates $DEPLOY_DIR/.env interactively (basic auth only -- everything else
# is either left at its docker-compose.prod.yml default or set manually per
# deploy/.env.example). Preserves an existing .env, just refreshing VM_IP.
create_env_file() {
    local env_file="$DEPLOY_DIR/.env"
    if [ ! -f "$env_file" ]; then
        echo "Creating .env file..."
        read -rp "Enter n8n basic auth username: " N8N_USER
        read -rsp "Enter n8n basic auth password: " N8N_PASS
        echo
        cat > "$env_file" <<EOF
VM_IP=$VM_IP
N8N_BASIC_AUTH_USER=$N8N_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_PASS
EOF
        chmod 600 "$env_file"
        echo ".env file created at $env_file"
    else
        sed -i "s/^VM_IP=.*/VM_IP=$VM_IP/" "$env_file"
        echo "Updated VM_IP in existing .env"
    fi
}

# Opens 80/443 via iptables. Ubuntu on GCP/AWS both default to iptables with
# no distro firewall in the way, but this alone is NOT sufficient on AWS --
# the EC2 Security Group also gates inbound traffic and must be opened
# separately in the console (setup-aws.sh documents this).
open_firewall_ports() {
    echo "Ensuring ports 80 and 443 are open (iptables)..."
    iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 443 -j ACCEPT
}

start_stack() {
    echo "Starting n8n and Caddy..."
    cd "$DEPLOY_DIR"
    docker compose up -d
}
