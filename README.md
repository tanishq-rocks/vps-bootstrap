# VPS Setup Script

A single Bash script that takes a freshly provisioned Ubuntu/Debian VPS and turns it into a secure, Docker-ready server in a few minutes.

## Why use this

Every new VPS starts out wide open: root login over SSH, no firewall, no automatic security patches, and none of the tooling you actually need. Doing this setup by hand is repetitive and easy to get wrong (or forget a step). This script automates the standard hardening + bootstrap checklist so every server you spin up starts from the same secure, known-good baseline — idempotent, logged, and safe to re-run.

## What it does

Run against a fresh root session, the script:

1. **Initial checks** — confirms it's running as root and that the OS supports `apt-get`/`systemd`, otherwise aborts.
2. **User setup** — prompts for a new non-root username, creates the account (via `adduser`, so you set the password interactively), and adds it to the `sudo` group.
3. **SSH hardening** — backs up `/etc/ssh/sshd_config`, then drops in `/etc/ssh/sshd_config.d/10-<project>.conf` to disable password-based **root** login (`PermitRootLogin prohibit-password`) while keeping key and password auth available for the new user. Validates the config with `sshd -t` before restarting SSH.
4. **Swap (optional)** — asks if you want a swap file for extra memory headroom, and if so, what size (e.g. `512M` or `2G`, default `1G`). Creates `/swapfile`, locks down its permissions, formats and enables it, and adds it to `/etc/fstab` so it persists across reboots. Useful on small (e.g. 1GB RAM) VPS instances where package upgrades and Docker workloads can exhaust memory. Once set up, you can check swap usage anytime with `htop` (look for the `Swp` meter near the top).
5. **System updates** — runs `apt-get update` and `apt-get upgrade -y`.
6. **Core packages & security** — installs `ufw`, `curl`, `wget`, `git`, `ca-certificates`, `gnupg`, `htop`, and `fail2ban` (enabled immediately to block brute-force login attempts).
7. **Auto-patching** — installs and configures `unattended-upgrades` so future security updates apply automatically.
8. **Firewall lockdown** — enables UFW: deny all incoming by default, allow all outgoing, explicitly allow SSH, HTTP (80), and HTTPS (443).
9. **Docker** — installs Docker Engine via the official `get.docker.com` script, enables the systemd service, and adds the new user to the `docker` group (so they can run containers without `sudo`).
10. **Final output** — prints the server's public IP and the command to reconnect as the new user, and reboots automatically if the kernel/packages require it.

### Safety & logging

- **Idempotent** — safe to run more than once (it detects existing users, existing SSH backups, existing Docker installs, etc.).
- **Backed up config** — your original `sshd_config` is copied to `sshd_config.bak` before any changes.
- **Clean logs** — all verbose install output is redirected to `/var/log/<project>-vps-setup.log` (named after the project name you enter at the start) so the terminal only shows step-by-step progress.

### What it does NOT do

You still need to do this manually afterward:

- Copy your SSH public key to the new user.
- Fully disable password-based SSH login. Once your key-based login works, set `PasswordAuthentication no` in `/etc/ssh/sshd_config.d/10-<project>.conf` and restart SSH.

## Quick Start

1. Spin up a fresh Ubuntu/Debian VPS and SSH in as root (or a user with root access).
2. Get the script onto the server and run it, using whichever option is easiest:

   **Option A — one-liner (no clone needed):**

   ```bash
   curl -fsSL https://raw.githubusercontent.com/tanishq-rocks/vps-bootstrap/main/vps-setup.sh | sudo bash
   ```

   **Option B — clone the repo:**

   ```bash
   git clone https://github.com/tanishq-rocks/vps-bootstrap.git
   cd vps-bootstrap
   sudo bash vps-setup.sh
   ```

3. Follow the prompts:
   - Enter a **project name** (used to label the log file and SSH config, e.g. `myapp`).
   - Enter a **username** for the new non-root user (defaults to `noname` if left blank), then set its password when `adduser` asks.
   - Choose whether to add **swap** for extra memory, and if so, a size (e.g. `512M` or `2G`, default `1G`).
4. Wait for the script to finish. It will print the server's IP and tell you how to reconnect. If a reboot is required, it reboots automatically after 5 seconds.
5. Reconnect as the new user:

   ```bash
   ssh <your-username>@<server-ip>
   ```

6. **Finish hardening manually:**
   - Copy your SSH public key to the new user (`ssh-copy-id <your-username>@<server-ip>`) and confirm key-based login works.
   - Edit `/etc/ssh/sshd_config.d/10-<project>.conf` and set `PasswordAuthentication no`, then restart SSH (`sudo systemctl restart ssh`).
   - See [POST-SETUP.md](POST-SETUP.md) for the full, safe step-by-step walkthrough (including how to avoid locking yourself out).
7. (Optional) Install [Dokploy](https://dokploy.com) for app deployment:

   ```bash
   curl -sSL https://dokploy.com/install.sh | sudo bash
   ```

## Requirements

- A fresh Ubuntu or Debian VPS with `apt-get` and `systemd`.
- Root access.
- An interactive terminal (the script reads input from `/dev/tty`, so it works even when piped).

## Logs

If anything fails, check the log file mentioned in the error message:

```bash
cat /var/log/<project>-vps-setup.log
```
