# 🛡️ VPS Backup — Automated rclone + Pterodactyl

> Fully automatic VPS backup to Google Drive every 3 hours.
> Covers system files, Pterodactyl Panel, Wings daemon, and all server volumes.
> One command setup on any new VPS.

---

## ✅ What Gets Backed Up

| Category | Paths |
|---|---|
| **System** | `/etc` `/var/www` `/home` `/root` `/opt` |
| **Pterodactyl Panel** | `/var/www/pterodactyl` + MySQL DB dump |
| **Wings Config & Data** | `/etc/pterodactyl` `/var/lib/pterodactyl` |
| **Server Volumes** | `/var/lib/pterodactyl/volumes/<uuid>/` (one archive per server) |

---

## 📁 Google Drive Layout

```
your-backup-folder/
├── system/
│   ├── system_001_2026-04-19_00-00.tar.gz
│   └── system_002_2026-04-19_03-00.tar.gz   ← max 2, oldest auto-deleted
├── pterodactyl/
│   ├── panel_001_2026-04-19_00-00.tar.gz
│   └── panel_002_2026-04-19_03-00.tar.gz
├── wings/
│   ├── wings_001_...tar.gz
│   └── wings_002_...tar.gz
└── volumes/
    └── <server-uuid>/
        ├── vol_<uuid>_001_...tar.gz
        └── vol_<uuid>_002_...tar.gz
```

**Archive naming:** `CATEGORY_BackupNumber_Date_Time.tar.gz`
- You can instantly tell what it is, which run it was, and when it was made
- Oldest backup is automatically deleted when a 3rd one is created
- Always exactly **2 backups** per category at any time

---

## 🚀 First Time Setup

### 1. Create a public GitHub repo

Go to [github.com/new](https://github.com/new) and create a repo:
- Name: `vps-backup-config` (or anything you like)
- Visibility: **Public**
- Tick **"Add a README file"** so it isn't empty

### 2. Run the setup script on your VPS

```bash
sudo bash vps_backup_setup.sh
```

The script will ask you for:
- Your **GitHub username** and **repo name**
- An **encryption password** — this encrypts your rclone config before it goes to GitHub. **Remember it, there is no recovery.**
- **rclone config** — it opens interactively, you sign into Google Drive
- A **one-time write token** to push files to your GitHub repo

> ⚠️ The write token is used once to push your config files and is never saved to disk.
> Create it at: [github.com/settings/personal-access-tokens/new](https://github.com/settings/personal-access-tokens/new)
> Settings: Repository → `vps-backup-config` | Permission → Contents: **Read and Write** only

### 3. Done

The first backup runs immediately. Every 3 hours after that it runs automatically.

---

## ⚡ New VPS Setup (30 seconds)

On any new VPS, just run this one command:

```bash
curl -fsSL https://raw.githubusercontent.com/HemanRathore/autobackup/main/vps_backup_setup.sh | sudo bash -s -- --from-github
```

It will:
1. Install rclone
2. Pull your encrypted rclone config from this repo
3. Ask for your **encryption password** to decrypt it
4. Auto-detect Pterodactyl & Wings
5. Set up the 3-hour timer
6. Run the first backup immediately

> Replace `YOUR_USERNAME` and `YOUR_REPO` with your actual GitHub username and repo name.

---

## ⏰ Schedule

Backups run at these fixed UTC times every day:

```
00:00  03:00  06:00  09:00  12:00  15:00  18:00  21:00
```

Uses systemd `OnCalendar` — immune to reboots and manual runs.
If the VPS was offline during a scheduled time, it catches up on next boot.

---

## 🔐 Security

- Your `rclone.conf` (Google Drive credentials) is encrypted with **AES-256-CBC** before being pushed to GitHub
- The encrypted file is completely useless without your password
- The GitHub repo can be public — nobody can do anything with the encrypted blob
- Your encryption password is **never stored anywhere** — only you know it

---

## 🛠️ Useful Commands

```bash
# Watch backup logs live
journalctl -u vps-rclone-backup -f

# View full log file
tail -f /var/log/vps-backup.log

# Trigger a manual backup right now
systemctl start vps-rclone-backup.service

# Check when the next backup is scheduled
systemctl list-timers vps-rclone-backup.timer

# Browse your Google Drive backups
rclone lsd YOUR_REMOTE:YOUR_FOLDER/

# List files in a specific category
rclone ls YOUR_REMOTE:YOUR_FOLDER/system/

# Disable automatic backups
systemctl disable --now vps-rclone-backup.timer

# Re-enable automatic backups
systemctl enable --now vps-rclone-backup.timer
```

---

## 🔄 Restoring a Backup

```bash
# Download a specific archive from Google Drive
rclone copy YOUR_REMOTE:YOUR_FOLDER/system/system_002_2026-04-19_03-00.tar.gz /tmp/restore/

# Extract it
tar -xzf /tmp/restore/system_002_2026-04-19_03-00.tar.gz -C /

# Restore a specific server volume
rclone copy YOUR_REMOTE:YOUR_FOLDER/volumes/<uuid>/ /tmp/restore/<uuid>/
tar -xzf /tmp/restore/<uuid>/vol_<uuid>_002_...tar.gz -C /
```

---

## 🗑️ Full Uninstall

```bash
rm -f /usr/local/bin/vps-backup.sh
systemctl disable --now vps-rclone-backup.timer vps-rclone-backup.service 2>/dev/null
rm -f /etc/systemd/system/vps-rclone-backup.{service,timer}
systemctl daemon-reload
rm -rf /var/backups/vps-staging
echo "Done — all backup files removed."
```

---

## 📋 What's Stored in This Repo

| File | Contents |
|---|---|
| `vps_backup_setup.sh` | The setup script — run this on any VPS |
| `backup-config/rclone.conf.enc` | AES-256 encrypted rclone credentials |
| `backup-config/settings.conf` | Remote name + backup folder name |

---

## ❓ FAQ

**Q: What if I forget my encryption password?**
You'll need to re-run `rclone config` on a working VPS to re-authenticate Google Drive, then run the setup script again to re-encrypt and push a new config.

**Q: Can I change how many backups are kept?**
Edit `/usr/local/bin/vps-backup.sh` and change `KEEP=2` to whatever number you want, then save.

**Q: What if Pterodactyl or Wings aren't installed?**
The script auto-detects them. If they're not found, those sections are silently skipped — system backup still runs normally.

**Q: Can I use a storage provider other than Google Drive?**
Yes — rclone supports S3, Backblaze B2, Dropbox, SFTP, and more. Just configure a different remote type during setup.

**Q: Will it work after a VPS reboot?**
Yes. `Persistent=true` in the timer means if a scheduled backup was missed during a reboot, it runs immediately when the VPS comes back online.
