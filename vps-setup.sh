#!/bin/bash
SCRIPT_VERSION="v1.1"
# ==============================================================================
# VPS Setup Script
# ==============================================================================
# This script takes a freshly provisioned Ubuntu/Debian VPS and secures it
# while preparing it for Docker-based deployments.
#
# EXACTLY WHAT THIS SCRIPT DOES:
# 0. Initial Checks: Ensures the script is run as root and verifies that
#    the OS supports apt-get and systemd before proceeding.
# 1. User Setup: Prompts to create a new non-root user, asks you to set a
#    password, and adds them to the sudo group.
# 2. SSH Hardening: Disables password-based root login while keeping
#    public-key auth enabled (password auth stays on for the new user —
#    see the README note about switching to key-only after this runs).
# 3. Swap (optional): Asks if you want a swap file for extra memory
#    headroom, and if so, how large — useful on small (e.g. 1GB RAM) VPS
#    instances where package upgrades and Docker workloads can exhaust RAM.
#    Swap usage can be checked anytime afterward with 'htop' (Swp meter).
# 4. System Updates: Updates package lists and upgrades all system packages.
# 5. Core Utilities & Security: Installs essential tools (ufw, curl, wget, git,
#    ca-certificates, gnupg, htop) and starts Fail2Ban to block malicious IPs.
# 6. Auto-Patching: Installs and configures 'unattended-upgrades' to
#    automatically apply security updates.
# 7. Firewall Lockdown: Enables UFW, denying all incoming traffic by default,
#    allowing outgoing traffic, and explicitly allowing SSH, HTTP (80),
#    HTTPS (443).
# 8. Docker Engine: Fetches the official Docker installation script, installs
#    Docker, enables the systemd service, and adds the new user to the 'docker'
#    group so containers can be run without 'sudo'.
# 9. Final Output: Dynamically fetches the server's public IP, prints
#    login instructions for the new user, and detects if a system reboot is
#    required.
#
# SAFETY & LOGGING:
# This script is idempotent (safe to run multiple times). It backs up your SSH
# config before modifying it. All verbose installation output is cleanly
# redirected to /var/log/<project>-vps-setup.log (named after the project
# name you enter when the script starts) to keep the terminal clean.
#
# NOT DONE HERE (do these manually afterward):
# - Copying your SSH public key to the new user
# - Fully disabling password-based SSH login (do this once your key works —
#   set PasswordAuthentication no in /etc/ssh/sshd_config.d/10-<project>.conf)
# ==============================================================================

set -uo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

LOG_FILE="/var/log/vps-setup.log"

die() {
    echo -e "\n${RED}❌ ERROR: $1${NC}"
    echo -e "${RED}Script aborted. Check log for possible details: cat $LOG_FILE${NC}"
    exit 1
}

step() {
    echo -e "\n${BLUE}====================================================${NC}"
    echo -e "${BLUE}[$1] $2${NC}"
    echo -e "${BLUE}====================================================${NC}"
}

ok() {
    echo -e "   ${GREEN}✔ Done${NC}"
}

info() {
    echo -e "   ${YELLOW}$1${NC}"
}

# Wait for background apt processes to release the dpkg lock
wait_for_apt() {
    if command -v fuser >/dev/null 2>&1; then
        while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/dpkg/lock >/dev/null 2>&1; do
            info "Waiting for background apt processes to finish..."
            sleep 5
        done
    fi
}

# ============================================================
# 0. INITIAL CHECKS
# ============================================================

[ "$EUID" -ne 0 ] && die "Run with: sudo bash vps-setup.sh"

command -v apt-get >/dev/null 2>&1 || die "Unsupported OS (Debian/Ubuntu required)"
command -v systemctl >/dev/null 2>&1 || die "Systemd required"

# ============================================================
# HEADER
# ============================================================

echo -e "${BLUE}====================================================${NC}"
echo -e "${GREEN}   VPS Setup ${SCRIPT_VERSION}${NC}"
echo -e "${BLUE}====================================================${NC}"
echo
echo "On a fresh VPS instance, this script:"
echo "- Creates a new user"
echo "- Makes SSH access more secure"
echo "- Optionally adds a swap file for extra memory"
echo "- Updates the system"
echo "- Installs recommended packages"
echo "- Enables automatic security updates"
echo "- Deny incoming traffic except SSH/HTTP/HTTPS/Dokploy with UFW"
echo "- Installs Docker"

# ============================================================
# PROJECT NAME
# ============================================================

echo
while true; do
    read -r -p "Enter your project name (used to label files, e.g. myapp): " PROJECT_NAME </dev/tty

    PROJECT_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
    PROJECT_NAME="${PROJECT_NAME#-}"
    PROJECT_NAME="${PROJECT_NAME%-}"

    if [ -z "$PROJECT_NAME" ]; then
        info "Error: Project name can't be empty. Use letters, numbers, spaces, or dashes."
        continue
    fi

    break
done

info "Using project name: $PROJECT_NAME"

LOG_FILE="/var/log/${PROJECT_NAME}-vps-setup.log"
echo "Starting $PROJECT_NAME VPS Setup ($SCRIPT_VERSION)..." > "$LOG_FILE"

# ============================================================
# 1. USER SETUP
# ============================================================

step "1/8" "Create a new user"

while true; do
    read -r -p "Enter username (default: noname): " NEW_USER </dev/tty

    if [ -z "${NEW_USER:-}" ]; then
        NEW_USER="noname"
        info "Using default user: noname"
    fi

    NEW_USER=$(echo "$NEW_USER" | tr '[:upper:]' '[:lower:]')

    if [[ "$NEW_USER" =~ ^(root|admin|ubuntu|daemon)$ ]]; then
        info "Error: '$NEW_USER' is a reserved name. Try again."
        continue
    fi

    if [[ ! "$NEW_USER" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
        info "Error: Invalid format. Must start with a letter and contain no spaces."
        continue
    fi

    break
done

if id "$NEW_USER" &>/dev/null; then
    info "User '$NEW_USER' already exists"
else
    adduser "$NEW_USER" </dev/tty \
        || die "Failed to create user '$NEW_USER'"
    info "Created user '$NEW_USER'"
fi

usermod -aG sudo "$NEW_USER" \
    || die "Failed to add '$NEW_USER' to sudo group"

info "Added user '$NEW_USER' to sudo group"

ok

# ============================================================
# 2. SSH SAFETY
# ============================================================

step "2/8" "Secure SSH"

SSH_CONFIG="/etc/ssh/sshd_config"
SSH_BACKUP="/etc/ssh/sshd_config.bak"
SSH_DROP_IN="/etc/ssh/sshd_config.d/10-${PROJECT_NAME}.conf"

if [ ! -f "$SSH_BACKUP" ]; then
    cp "$SSH_CONFIG" "$SSH_BACKUP" \
        || die "Failed to back up SSH config"

    info "Backed up SSH config"
fi

cat > "$SSH_DROP_IN" <<EOF || die "Failed to write SSH configuration"
PermitRootLogin prohibit-password
PasswordAuthentication yes
PubkeyAuthentication yes
EOF

if ! sshd -t; then
    rm -f "$SSH_DROP_IN"
    die "Invalid SSH configuration"
fi

if [ "$(sshd -T | awk '$1 == "passwordauthentication" {print $2}')" != "yes" ]; then
    rm -f "$SSH_DROP_IN"
    die "Password authentication is being overridden by another SSH configuration"
fi

systemctl restart ssh 2>/dev/null \
    || systemctl restart sshd \
    || die "Failed to restart SSH"

info "Secured and restarted SSH"

ok

# ============================================================
# 3. SWAP
# ============================================================

step "3/8" "Configure swap"

read -r -p "Add a swap file for extra memory? (y/N): " ADD_SWAP </dev/tty
ADD_SWAP=$(echo "$ADD_SWAP" | tr '[:upper:]' '[:lower:]')

if [[ "$ADD_SWAP" =~ ^y(es)?$ ]]; then
    if swapon --show | grep -q . || [ -f /swapfile ]; then
        info "Swap is already configured, skipping"
    else
        while true; do
            read -r -p "Swap size, e.g. 512M or 2G (default: 1G): " SWAP_SIZE </dev/tty
            SWAP_SIZE=$(echo "${SWAP_SIZE:-1G}" | tr '[:lower:]' '[:upper:]')

            [[ "$SWAP_SIZE" =~ ^[0-9]+[MG]$ ]] && break
            info "Error: Enter a number followed by M or G, e.g. 512M or 2G."
        done

        fallocate -l "$SWAP_SIZE" /swapfile \
            || die "Failed to allocate swap file"

        chmod 600 /swapfile \
            || die "Failed to set swap file permissions"

        mkswap /swapfile >> "$LOG_FILE" 2>&1 \
            || die "Failed to format swap file"

        swapon /swapfile \
            || die "Failed to enable swap"

        grep -q '^/swapfile ' /etc/fstab \
            || echo '/swapfile none swap sw 0 0' >> /etc/fstab

        info "Created and enabled a ${SWAP_SIZE} swap file at /swapfile"
        info "Tip: run 'htop' later to see swap usage (Swp meter near the top)"
    fi
else
    info "Skipping swap setup"
fi

ok

# ============================================================
# 4. SYSTEM UPDATE
# ============================================================

step "4/8" "Updating system"

wait_for_apt
apt-get update -qq >> "$LOG_FILE" 2>&1 || die "apt update failed"
info "Updated package lists"

wait_for_apt
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq >> "$LOG_FILE" 2>&1 || die "upgrade failed"
info "Upgraded system packages"

ok

# ============================================================
# 5. RECOMMENDED PACKAGES
# ============================================================

step "5/8" "Installing recommended packages"

PACKAGES="ufw curl wget git ca-certificates gnupg fail2ban htop"

wait_for_apt
DEBIAN_FRONTEND=noninteractive apt-get install -y $PACKAGES \
>> "$LOG_FILE" 2>&1 || die "package install failed"

systemctl enable --now fail2ban >> "$LOG_FILE" 2>&1 \
    || die "Failed to enable or start Fail2Ban"

info "Installed the following packages:"
for pkg in $PACKAGES; do
    echo -e "   ${YELLOW}- $pkg${NC}"
done

ok

# ============================================================
# 6. SECURITY UPDATES
# ============================================================

step "6/8" "Enabling automatic security updates"

wait_for_apt
DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades \
>> "$LOG_FILE" 2>&1 || die "failed to install unattended-upgrades"

echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections \
    >> "$LOG_FILE" 2>&1 || die "failed to configure unattended-upgrades"

DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -f noninteractive unattended-upgrades \
    >> "$LOG_FILE" 2>&1 \
    || die "failed to enable unattended-upgrades"

info "Enabled automatic security updates"

ok

# ============================================================
# 7. FIREWALL
# ============================================================

step "7/8" "Configuring ufw firewall"

ufw default deny incoming >> "$LOG_FILE" 2>&1 || die "ufw deny incoming failed"
info "Set default policy: Deny incoming"

ufw default allow outgoing >> "$LOG_FILE" 2>&1 || die "ufw allow outgoing failed"
info "Set default policy: Allow outgoing"

ufw allow OpenSSH >> "$LOG_FILE" 2>&1 || die "ufw ssh rule failed"
info "Allowed SSH traffic"

# HTTP/HTTPS for real traffic
ufw allow 80/tcp >> "$LOG_FILE" 2>&1 || die "ufw http rule failed"
ufw allow 443/tcp >> "$LOG_FILE" 2>&1 || die "ufw https rule failed"
info "Allowed HTTP (80), HTTPS (443) traffic"

ufw --force enable >> "$LOG_FILE" 2>&1 || die "ufw enable failed"
info "Enabled UFW firewall"

ok

# ============================================================
# 8. DOCKER
# ============================================================

step "8/8" "Installing Docker"

if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o /tmp/docker.sh \
        >> "$LOG_FILE" 2>&1 \
        || die "docker download failed"

    info "Downloaded Docker install script"

    wait_for_apt
    sh /tmp/docker.sh >> "$LOG_FILE" 2>&1 \
        || die "docker install failed"

    info "Installed Docker Engine"
else
    info "Docker already installed"
fi

systemctl enable --now docker >> "$LOG_FILE" 2>&1 \
    || die "Docker service start failed"

info "Started Docker daemon"

usermod -aG docker "$NEW_USER" >> "$LOG_FILE" 2>&1 || die "docker group add failed"
info "Added user '$NEW_USER' to docker group"

ok

# ============================================================
# FINAL OUTPUT
# ============================================================

echo -e "\n${BLUE}====================================================${NC}"
echo -e "${GREEN}            🎉 SETUP COMPLETE                       ${NC}"
echo -e "${BLUE}====================================================${NC}\n"

IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
[ -z "$IP" ] && IP=$(hostname -I | awk '{print $1}')
[ -z "$IP" ] && IP="YOUR_SERVER_IP"

echo "🚨 IMPORTANT NEXT STEPS:"
echo -e "⚠ Log out and reconnect before running Docker as the new user.\n"

if [ -f /var/run/reboot-required ]; then
    echo -e "${YELLOW}Reboot required. Server restarting in 5 seconds...${NC}"
    echo -e "Once it boots up, reconnect using: ${GREEN}ssh $NEW_USER@$IP${NC}\n"
    sleep 5
    reboot
else
    echo "1. Type 'exit' to log out of this root session."
    echo -e "2. Reconnect using: ${GREEN}ssh $NEW_USER@$IP${NC}\n"
fi

echo "Next up: copy your SSH public key to \$NEW_USER, confirm key login works,"
echo "then set PasswordAuthentication no in $SSH_DROP_IN"
echo "and restart ssh. After that, install Dokploy:"
echo -e "${GREEN}curl -sSL https://dokploy.com/install.sh | sudo bash${NC}\n"
