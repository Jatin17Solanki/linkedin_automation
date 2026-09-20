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

# Prompts for one value, echoes it back, and asks the user to confirm before
# accepting it. Unlike a password, these values (API keys, numeric chat IDs)
# are wrong in a way that isn't obvious from the prompt alone -- a typo just
# silently breaks Telegram/Gemini later with no error pointing back here, so
# showing what was typed and requiring an explicit "yes" catches it up front.
# Leaving the input blank skips it (documented as settable later).
# Result is written into the caller-named variable (nameref-by-string, bash
# 3.2-safe via `printf -v` rather than `declare -n`, since setup-gcp.sh/
# setup-aws.sh run under plain `bash`, no guaranteed 4.3+).
prompt_confirmed_value() {
    local prompt_label="$1"
    local var_name="$2"
    local value=""
    local confirm=""
    while true; do
        read -rp "$prompt_label (leave blank to skip and set later): " value
        if [ -z "$value" ]; then
            echo "Skipped -- you can set this later, see \"Updating these values later\" in SETUP_GUIDE.md."
            break
        fi
        echo "You entered: $value"
        read -rp "Is this correct? (y/n): " confirm
        case "$confirm" in
            [Yy]*) break ;;
            *) echo "Let's try that again." ;;
        esac
    done
    printf -v "$var_name" '%s' "$value"
}

# Creates $DEPLOY_DIR/.env interactively -- n8n basic auth (masked), plus
# GEMINI_API_KEY/TELEGRAM_CHAT_ID (shown + confirmed, see prompt_confirmed_value
# above) since without those two, LLM matching and Telegram notifications
# silently don't work with no error pointing back at a missing env var.
# Everything else stays at its docker-compose.prod.yml default or gets set
# manually per deploy/.env.example. Preserves an existing .env, just
# refreshing VM_IP -- re-running this script never re-prompts or overwrites
# values you already set.
create_env_file() {
    local env_file="$DEPLOY_DIR/.env"
    if [ ! -f "$env_file" ]; then
        echo "Creating .env file..."
        echo ""
        echo "-- n8n web UI login --"
        echo "IMPORTANT: save this username/password somewhere durable (password manager,"
        echo "not just your terminal scrollback) -- this is what you'll use to log into"
        echo "the n8n web UI at https://<VM_IP>.nip.io once the stack is up. It is NOT"
        echo "shown again after this prompt, and there's no 'forgot password' recovery --"
        echo "if you lose it, you'd need to re-edit $DEPLOY_DIR/.env by hand to reset it."
        read -rp "Enter n8n basic auth username: " N8N_USER
        read -rsp "Enter n8n basic auth password: " N8N_PASS
        echo
        echo ""
        echo "-- Required for LLM resume matching + Telegram notifications --"
        echo "Get these ready beforehand if you haven't already:"
        echo "  Gemini API key: https://aistudio.google.com/apikey (free, no billing account needed)"
        echo "  Telegram chat ID: message @userinfobot on Telegram"
        echo ""
        prompt_confirmed_value "Enter your Gemini API key" GEMINI_KEY
        prompt_confirmed_value "Enter your Telegram chat ID" TELEGRAM_ID
        cat > "$env_file" <<EOF
VM_IP=$VM_IP
N8N_BASIC_AUTH_USER=$N8N_USER
N8N_BASIC_AUTH_PASSWORD=$N8N_PASS
GEMINI_API_KEY=$GEMINI_KEY
TELEGRAM_CHAT_ID=$TELEGRAM_ID
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
