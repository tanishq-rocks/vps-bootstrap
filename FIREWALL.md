# Firewall: View & Configure

Traffic to your VPS can be blocked at **two separate layers**:

1. **Host firewall (UFW)** — runs on the VPS itself. `vps-setup.sh` already configures this (deny incoming by default, allow SSH/80/443).
2. **Provider network firewall** — a separate layer many VPS providers offer (cloud firewall / security group) that filters traffic *before it ever reaches your VPS*.

**Both layers must allow a port for traffic to get through.** If either one blocks it, the connection fails — so when something doesn't work, always check both.

## 1. Host firewall (UFW) — on the VPS

### View current rules

```bash
sudo ufw status verbose
```

For rule numbers (needed to delete a specific rule):

```bash
sudo ufw status numbered
```

`vps-setup.sh` leaves you with: deny all incoming by default, allow all outgoing, and SSH, HTTP (80), HTTPS (443) explicitly allowed.

### Allow a new port

```bash
sudo ufw allow 3000/tcp          # a specific TCP port
sudo ufw allow 51820/udp         # a specific UDP port
sudo ufw allow 8000:8010/tcp     # a port range
```

### Allow a port only from a specific IP (more secure than opening it to everyone)

```bash
sudo ufw allow from <your-ip> to any port 3000
```

### Remove a rule

```bash
sudo ufw status numbered     # find the rule's number
sudo ufw delete <number>
```

### Deny a port explicitly

```bash
sudo ufw deny 8080/tcp
```

### Temporarily disable / re-enable

```bash
sudo ufw disable
sudo ufw enable
```

### Common ports for reference

| Port | Use |
|------|-----|
| 22 | SSH |
| 80 | HTTP |
| 443 | HTTPS |
| 3000 | Dokploy dashboard (default — check your install for the actual port) |
| 2377, 7946, 4789 | Docker Swarm (only if you use it) |

Only open what you actually need — every open port is something to defend.

## 2. Provider network firewall — outside the VPS

This lives in your VPS provider's dashboard, not on the server, and is usually called **"Firewall"**, **"Security Group"**, or **"Network Rules"**. It filters traffic at the network edge, so even a port UFW allows will be unreachable if the provider firewall blocks it first.

General steps (menu names vary by provider — DigitalOcean, Hetzner, AWS, Vultr, Linode, Google Cloud, Azure, etc. all offer this, just under different names):

1. Log in to your VPS provider's dashboard.
2. Find the **Firewall** / **Security Group** / **Network** section for your project or account.
3. Add **inbound** rules that mirror what you opened in UFW — at minimum SSH (22), HTTP (80), HTTPS (443), plus any app-specific ports (e.g. Dokploy's dashboard port).
4. Make sure the firewall/security group is actually **attached to your specific VPS instance** — on many providers, creating the rule isn't enough; it also has to be applied to the server.
5. Outbound traffic is usually allowed by default; only lock it down if you have a specific reason to.

> Tip: keep UFW and the provider firewall in sync. A common mistake is opening a port in one and forgetting the other, then assuming the service itself is broken.

## 3. Troubleshooting checklist

If a service on `<port>` isn't reachable from outside:

1. **Is UFW allowing it?**
   ```bash
   sudo ufw status | grep <port>
   ```
2. **Is anything actually listening on that port?**
   ```bash
   sudo ss -tulpn | grep <port>
   ```
3. **Does the provider firewall/security group allow it?** Check the dashboard — this is the most commonly missed step.
4. **Test locally on the server first** (rules out an app-level problem):
   ```bash
   curl -I localhost:<port>
   ```
5. **Test from outside the server**:
   ```bash
   curl -I http://<server-ip>:<port>
   # or, for a raw TCP check:
   nc -zv <server-ip> <port>
   ```

### Locked out by Fail2Ban?

`vps-setup.sh` enables Fail2Ban, which auto-bans IPs after repeated failed SSH logins. If you get banned (e.g. from testing), unban yourself from the server console or another session:

```bash
sudo fail2ban-client status sshd        # see banned IPs
sudo fail2ban-client set sshd unbanip <your-ip>
```
