# Finish Hardening: Switch to Key-Only SSH

This is the detailed walkthrough for **step 7** of the [Quick Start](README.md#quick-start) in the README: *"Finish hardening manually."*

`vps-setup.sh` intentionally leaves password authentication turned on for your new user. If it disabled passwords automatically, and your SSH key didn't work for any reason, you'd be locked out of the server with no way back in. These steps close that gap safely, in the right order, so you never lose access.

> ⚠️ **Golden rule:** never close your original root/SSH session until you've confirmed key-based login works in a *second*, separate terminal window. If step 3 fails, your first session is still open and you can fix it.

## 1. Check if you already have an SSH key

On your **local machine** (not the server), run:

```bash
ls ~/.ssh/id_ed25519.pub 2>/dev/null || ls ~/.ssh/id_rsa.pub 2>/dev/null
```

If a path is printed, you already have a key pair — skip to [step 2](#2-copy-your-public-key-to-the-server).

If nothing is printed, generate one:

```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

Press Enter to accept the default location, and set a passphrase if you'd like (recommended).

**Want a custom name instead** (useful if you manage keys for multiple servers)? Pass `-f` with a path:

```bash
ssh-keygen -t ed25519 -C "your_email@example.com" -f ~/.ssh/<key-name>
```

This creates `~/.ssh/<key-name>` (private key) and `~/.ssh/<key-name>.pub` (public key). Replace `<key-name>` with whatever you'd like, e.g. `~/.ssh/myserver`.

## 2. Copy your public key to the server

The easiest way, from your **local machine**:

```bash
ssh-copy-id <your-username>@<server-ip>
```

If you used the default key name, `ssh-copy-id` finds it automatically. If you gave your key a **custom name**, point at it explicitly with `-i`:

```bash
ssh-copy-id -i ~/.ssh/<key-name>.pub <your-username>@<server-ip>
```

This appends your public key to `~/.ssh/authorized_keys` for that user on the server. You'll be prompted for the user's password (the one you set during `adduser` when running `vps-setup.sh`).

**If `ssh-copy-id` isn't available** (e.g. on some minimal shells), do it manually — swap in your key's filename if it's not the default:

```bash
cat ~/.ssh/<key-name>.pub | ssh <your-username>@<server-ip> "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

## 3. Verify key-based login works

**Open a brand-new terminal window** (leave your existing session alone) and connect:

```bash
ssh <your-username>@<server-ip>
```

If you used a **custom key name** in step 1, SSH won't pick it up automatically — point at it explicitly:

```bash
ssh -i ~/.ssh/<key-name> <your-username>@<server-ip>
```

(To avoid typing `-i` every time, add an entry to `~/.ssh/config` — see the [tip](#tip-avoid-typing--i-every-time-with-a-custom-key) at the end of this section.)

You should log in **without being asked for a password**. If you set a passphrase on your key, you'll be asked for that instead — that's expected and fine.

- ✅ Logged in without a password prompt → continue to step 4.
- ❌ Still asked for a password, or connection refused → **stop here**, do not proceed. Re-check steps 1–2. Your original session is still open, so you're safe.

#### Tip: avoid typing `-i` every time with a custom key

Add a block to `~/.ssh/config` on your local machine:

```
Host <server-ip>
    User <your-username>
    IdentityFile ~/.ssh/<key-name>
```

Afterward, plain `ssh <server-ip>` (or even `ssh <alias>` if you set `Host` to a short alias) will use the right key automatically.

## 4. Disable password authentication

Once key login is confirmed working, go back to your **original root/sudo session** on the server and edit the drop-in config the script created:

```bash
sudo nano /etc/ssh/sshd_config.d/10-<project>.conf
```

(Replace `<project>` with the project name you entered when running `vps-setup.sh`.)

Change this line:

```
PasswordAuthentication yes
```

to:

```
PasswordAuthentication no
```

Save and exit (`Ctrl+O`, `Enter`, `Ctrl+X` in nano).

## 5. Validate and restart SSH

Always test the config before restarting, so a typo can't lock you out:

```bash
sudo sshd -t
```

No output means the config is valid. If you see an error, fix it before continuing.

Restart SSH:

```bash
sudo systemctl restart ssh || sudo systemctl restart sshd
```

## 6. Confirm password login is actually blocked

Open **yet another new terminal** and try connecting with password auth forced:

```bash
ssh -o PubkeyAuthentication=no <your-username>@<server-ip>
```

This should now be **refused** (`Permission denied (publickey)`). If it still accepts a password, re-check that you edited the correct file and restarted the right service.

Your normal key-based login (`ssh <your-username>@<server-ip>`) should keep working as before.

## Done

Your server now only accepts SSH connections from machines holding your private key. From here, you can optionally continue with the last Quick Start item — installing [Dokploy](https://dokploy.com):

```bash
curl -sSL https://dokploy.com/install.sh | sudo bash
```

## Troubleshooting

- **Locked out after restarting SSH?** If you still have your original session open, you're fine — go back, review `/etc/ssh/sshd_config.d/10-<project>.conf`, and set `PasswordAuthentication yes` again temporarily, restart SSH, then retry.
- **Lost all sessions and can't reconnect?** Most VPS providers offer a browser-based "console" or "recovery mode" access to the server that bypasses SSH entirely — use that to fix the config.
- **Restore the original SSH config entirely:** the script backed it up before making changes:

  ```bash
  sudo cp /etc/ssh/sshd_config.bak /etc/ssh/sshd_config
  sudo rm /etc/ssh/sshd_config.d/10-<project>.conf
  sudo systemctl restart ssh
  ```
