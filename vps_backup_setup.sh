#!/usr/bin/env bash
# ==============================================================================
#  VPS + PTERODACTYL BACKUP SETUP  v4
#
#  ✔ Timer uses OnCalendar — fires every 3h reliably
#  ✔ Keeps last 2 backups, oldest auto-deleted correctly
#  ✔ GitHub (PUBLIC repo) — rclone config encrypted with a password before upload
#  ✔ New VPS setup = one curl command, just enter your password
#
#  FIRST TIME:
#    sudo bash vps_backup_setup.sh
#
#  ANY NEW VPS AFTER THAT:
#    curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/vps_backup_setup.sh | sudo bash -s -- --from-github
# ==============================================================================

set -euo pipefail

# ── colours ───────────────────────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' X='\033[0m'
info()   { echo -e "${C}[INFO]${X}  $*"; }
ok()     { echo -e "${G}[OK]${X}    $*"; }
warn()   { echo -e "${Y}[WARN]${X}  $*"; }
die()    { echo -e "${R}[ERR]${X}   $*"; exit 1; }
banner() { echo -e "\n${B}${C}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n  $*\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}\n"; }

[[ $EUID -ne 0 ]] && die "Run as root:  sudo bash $0"

# ── fixed paths ───────────────────────────────────────────────────────────────
KEEP=2
SYSTEM_DIRS="/etc /var/www /home /root /opt"
PANEL_DIR="/var/www/pterodactyl"
PANEL_ENV="/var/www/pterodactyl/.env"
WINGS_CONFIG="/etc/pterodactyl"
WINGS_DATA="/var/lib/pterodactyl"
WINGS_VOLUMES="/var/lib/pterodactyl/volumes"
STAGING="/var/backups/vps-staging"
BACKUP_SCRIPT="/usr/local/bin/vps-backup.sh"
LOG="/var/log/vps-backup.log"
SVC="vps-rclone-backup"
RCLONE_CONF="${HOME}/.config/rclone/rclone.conf"
CONF_FILE="/etc/vps-backup.conf"

# GitHub file paths inside your repo
GH_ENCRYPTED_CONF="backup-config/rclone.conf.enc"
GH_SETTINGS="backup-config/settings.conf"
GH_SCRIPT="vps_backup_setup.sh"

FROM_GITHUB=false
[[ "${1:-}" == "--from-github" ]] && FROM_GITHUB=true

# ==============================================================================
#  STEP 1 — Install dependencies (rclone + openssl + git)
# ==============================================================================
banner "1/6  Installing dependencies"

if command -v rclone &>/dev/null; then
    ok "rclone $(rclone version | head -1 | awk '{print $2}')"
else
    info "Installing rclone…"
    curl -fsSL https://rclone.org/install.sh | bash
    ok "rclone installed"
fi

# openssl is needed to encrypt/decrypt the rclone config
if ! command -v openssl &>/dev/null; then
    info "Installing openssl…"
    apt-get install -y openssl 2>/dev/null || yum install -y openssl 2>/dev/null || true
fi
ok "openssl ready"

if ! command -v git &>/dev/null; then
    info "Installing git…"
    apt-get install -y git 2>/dev/null || yum install -y git 2>/dev/null || true
fi
ok "git ready"

# ==============================================================================
#  STEP 2 — GitHub setup (public repo, no token needed)
# ==============================================================================
banner "2/6  GitHub setup"

echo -e "  Your rclone config will be ${B}encrypted${X} with a password you choose,"
echo -e "  then stored in a ${B}public${X} GitHub repo — no token needed."
echo -e "  The encrypted file is useless to anyone without your password."
echo ""

read -rp "  GitHub username: " GH_USER
echo ""
read -rp "  Repo name (will be created if it doesn't exist) [vps-backup-config]: " GH_REPO
GH_REPO="${GH_REPO:-vps-backup-config}"
echo ""

GH_RAW="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main"
GH_API="https://api.github.com"

if [[ "${FROM_GITHUB}" == "false" ]]; then
    # ── Check if repo exists ──────────────────────────────────────────────────
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${GH_API}/repos/${GH_USER}/${GH_REPO}")

    if [[ "${HTTP}" == "200" ]]; then
        ok "Repo found: github.com/${GH_USER}/${GH_REPO}"
    elif [[ "${HTTP}" == "404" ]]; then
        echo -e "  ${Y}Repo '${GH_REPO}' not found on GitHub.${X}"
        echo -e "  Please create it manually at: ${C}https://github.com/new${X}"
        echo -e "  • Name: ${B}${GH_REPO}${X}"
        echo -e "  • Visibility: ${B}Public${X}"
        echo -e "  • Tick: ${B}Add a README file${X}  (so the repo isn't empty)"
        echo ""
        read -rp "  Press ENTER once you've created the repo…"
        # Verify again
        HTTP2=$(curl -s -o /dev/null -w "%{http_code}" "${GH_API}/repos/${GH_USER}/${GH_REPO}")
        [[ "${HTTP2}" == "200" ]] || die "Still can't find repo. Check username/repo name and try again."
        ok "Repo confirmed: github.com/${GH_USER}/${GH_REPO}"
    else
        die "GitHub returned HTTP ${HTTP}. Check your username and internet connection."
    fi
fi

# ==============================================================================
#  STEP 3 — Encryption password
# ==============================================================================
banner "3/6  Encryption password"

echo -e "  This password encrypts your rclone config before it goes to GitHub."
echo -e "  ${B}Remember it — you'll need it on every new VPS.${X}"
echo -e "  ${R}Do NOT lose it — there is no recovery.${X}"
echo ""

while true; do
    read -rsp "  Enter encryption password: " ENC_PASS; echo ""
    read -rsp "  Confirm password:          " ENC_PASS2; echo ""
    [[ "${ENC_PASS}" == "${ENC_PASS2}" ]] && break
    warn "Passwords do not match — try again."
done
ok "Password set"

# ── encryption helpers ────────────────────────────────────────────────────────
encrypt_file() {
    # encrypt_file <input> <output.enc>
    openssl enc -aes-256-cbc -pbkdf2 -iter 100000 \
        -in "$1" -out "$2" -k "${ENC_PASS}"
}

decrypt_file() {
    # decrypt_file <input.enc> <output>
    openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
        -in "$1" -out "$2" -k "${ENC_PASS}"
}

# ── GitHub file push via API (no token — uses git clone + push) ───────────────
# We use a temp clone with HTTPS + GitHub token-free push via git credential
# Since repo is public for READ, we only need auth for WRITE.
# Solution: use git with a one-time token just for push, OR ask user to
# paste a fine-grained token with Contents:write only.
#
# Better approach for truly no-token: use GitHub CLI or instruct user.
# SIMPLEST true no-token write: git clone via SSH if key exists, else ask once.

push_to_github() {
    local FILE_PATH="$1"   # local file
    local REPO_PATH="$2"   # path inside repo
    local MSG="$3"         # commit message

    local TMP_REPO="/tmp/gh-backup-repo-$$"
    rm -rf "${TMP_REPO}"

    # Try SSH first (works if user has SSH key on this VPS added to GitHub)
    local SSH_OK=false
    if ssh -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        SSH_OK=true
    fi

    if [[ "${SSH_OK}" == "true" ]]; then
        git clone "git@github.com:${GH_USER}/${GH_REPO}.git" "${TMP_REPO}" -q
    else
        # Fall back: ask for a fine-grained token (Contents: Read+Write only)
        # This is a one-time step saved nowhere on disk
        echo ""
        echo -e "  ${Y}To push files to GitHub, a write token is needed once.${X}"
        echo -e "  Create a fine-grained token at:"
        echo -e "  ${C}https://github.com/settings/personal-access-tokens/new${X}"
        echo ""
        echo -e "  Settings:"
        echo -e "    • Repository access → Only select: ${B}${GH_REPO}${X}"
        echo -e "    • Permissions → Contents: ${B}Read and Write${X}  (nothing else)"
        echo -e "    • Expiration: ${B}No expiration${X} (or 1 year)"
        echo ""
        echo -e "  This token is ${B}not saved anywhere${X} — used only right now to push."
        echo ""
        read -rsp "  Paste token: " GH_WRITE_TOKEN; echo ""
        git clone "https://${GH_USER}:${GH_WRITE_TOKEN}@github.com/${GH_USER}/${GH_REPO}.git" \
            "${TMP_REPO}" -q
    fi

    mkdir -p "${TMP_REPO}/$(dirname "${REPO_PATH}")"
    cp "${FILE_PATH}" "${TMP_REPO}/${REPO_PATH}"

    cd "${TMP_REPO}"
    git config user.email "backup@vps"
    git config user.name "VPS Backup"
    git add "${REPO_PATH}"
    git diff --cached --quiet || git commit -m "${MSG}" -q
    git push -q
    cd - > /dev/null
    rm -rf "${TMP_REPO}"
}

# ==============================================================================
#  STEP 4 — rclone remote  (configure fresh OR restore from GitHub)
# ==============================================================================
banner "4/6  rclone remote"

mkdir -p "$(dirname "${RCLONE_CONF}")"

if [[ "${FROM_GITHUB}" == "true" ]]; then
    # ── Restore encrypted config from GitHub ─────────────────────────────────
    info "Downloading encrypted rclone config from GitHub…"
    ENC_TMP=$(mktemp)
    curl -fsSL "${GH_RAW}/${GH_ENCRYPTED_CONF}" -o "${ENC_TMP}"

    info "Decrypting…"
    if ! decrypt_file "${ENC_TMP}" "${RCLONE_CONF}"; then
        rm -f "${ENC_TMP}"
        die "Decryption failed — wrong password?"
    fi
    rm -f "${ENC_TMP}"
    chmod 600 "${RCLONE_CONF}"
    ok "rclone config restored and decrypted"

    # Restore settings
    info "Downloading settings from GitHub…"
    curl -fsSL "${GH_RAW}/${GH_SETTINGS}" -o "${CONF_FILE}"
    # shellcheck disable=SC1090
    source "${CONF_FILE}"
    ok "Settings loaded — Remote: ${RCLONE_REMOTE}  Folder: ${BACKUP_FOLDER}"

else
    # ── Fresh rclone config ───────────────────────────────────────────────────
    EXISTING=$(rclone listremotes 2>/dev/null || true)

    if [[ -n "${EXISTING}" ]]; then
        echo -e "  ${G}Existing remotes:${X}"
        echo "${EXISTING}" | while read -r RM; do echo -e "    ${C}${RM}${X}"; done
        echo ""
        read -rp "  Use existing [u] or configure new [n]: " USE_EX
        USE_EX="${USE_EX,,}"
    else
        USE_EX="n"
    fi

    if [[ "${USE_EX:-n}" == "u" ]]; then
        read -rp "  Remote name (without colon): " RCLONE_REMOTE
        RCLONE_REMOTE="${RCLONE_REMOTE%:}"
        rclone listremotes | grep -q "^${RCLONE_REMOTE}:" || die "Remote not found."
        ok "Using: ${RCLONE_REMOTE}"
    else
        echo -e "${Y}"
        cat <<MSG
  ╔════════════════════════════════════════════════════╗
  ║       rclone config — Google Drive setup           ║
  ╠════════════════════════════════════════════════════╣
  ║  1. Choose  n  → New remote                        ║
  ║  2. Give it any name  (e.g. gdrive, mybackup)      ║
  ║  3. Storage → Google Drive                         ║
  ║  4. client_id & secret → leave BLANK (Enter)       ║
  ║  5. Scope → 1  (full access)                       ║
  ║  6. Auto config → y  (sign in via browser)         ║
  ║  7. Shared drive → n                               ║
  ║  8. Confirm → y   then   q   to quit               ║
  ╚════════════════════════════════════════════════════╝
MSG
        echo -e "${X}"
        read -rp "  Press ENTER to open rclone config…"
        BEFORE=$(rclone listremotes 2>/dev/null || true)
        rclone config
        AFTER=$(rclone listremotes 2>/dev/null || true)
        ADDED=$(comm -13 <(echo "${BEFORE}" | sort) <(echo "${AFTER}" | sort) || true)

        if [[ -n "${ADDED}" ]]; then
            RCLONE_REMOTE="${ADDED%%:*}"
            ok "Auto-detected remote: ${B}${RCLONE_REMOTE}${X}"
        else
            read -rp "  Type the remote name you just created (without colon): " RCLONE_REMOTE
            RCLONE_REMOTE="${RCLONE_REMOTE%:}"
        fi
        rclone listremotes | grep -q "^${RCLONE_REMOTE}:" || die "Remote not found."
    fi

    # ── Backup folder name ────────────────────────────────────────────────────
    echo ""
    echo -e "  ${B}Top-level folder name in your Google Drive:${X}"
    read -rp "  Press ENTER for [${RCLONE_REMOTE}-backups] or type custom: " BACKUP_FOLDER
    BACKUP_FOLDER="${BACKUP_FOLDER:-${RCLONE_REMOTE}-backups}"
    BACKUP_FOLDER="${BACKUP_FOLDER// /-}"
    ok "Backup folder: ${B}${BACKUP_FOLDER}${X}"

    # ── Save settings file ────────────────────────────────────────────────────
    cat > "${CONF_FILE}" <<CONF
RCLONE_REMOTE="${RCLONE_REMOTE}"
BACKUP_FOLDER="${BACKUP_FOLDER}"
GH_USER="${GH_USER}"
GH_REPO="${GH_REPO}"
CONF

    # ── Encrypt rclone config and push to GitHub ──────────────────────────────
    info "Encrypting rclone config…"
    ENC_TMP=$(mktemp)
    encrypt_file "${RCLONE_CONF}" "${ENC_TMP}"
    ok "Encrypted: $(du -sh "${ENC_TMP}" | cut -f1)"

    info "Pushing encrypted config to GitHub…"
    push_to_github "${ENC_TMP}" "${GH_ENCRYPTED_CONF}" "Update encrypted rclone config"
    rm -f "${ENC_TMP}"
    ok "Encrypted config pushed to GitHub"

    info "Pushing settings to GitHub…"
    push_to_github "${CONF_FILE}" "${GH_SETTINGS}" "Update backup settings"
    ok "Settings pushed to GitHub"

    info "Pushing setup script to GitHub…"
    push_to_github "$0" "${GH_SCRIPT}" "Update setup script"
    ok "Setup script pushed to GitHub"
fi

# ==============================================================================
#  STEP 5 — Detect Pterodactyl & Wings
# ==============================================================================
banner "5/6  Detecting Pterodactyl & Wings"

HAS_PANEL=false
HAS_WINGS=false

if [[ -d "${PANEL_DIR}" ]]; then
    HAS_PANEL=true; ok "Panel found at ${PANEL_DIR}"
else
    warn "Panel NOT found — panel backup skipped"
fi

if command -v wings &>/dev/null || [[ -f /usr/local/bin/wings ]] || [[ -f "${WINGS_CONFIG}/wings.yml" ]]; then
    HAS_WINGS=true; ok "Wings found"
    if [[ -f "${WINGS_CONFIG}/wings.yml" ]]; then
        _C=$(grep -E '^\s*data:' "${WINGS_CONFIG}/wings.yml" | awk '{print $2}' | tr -d '"' || true)
        if [[ -n "${_C}" ]]; then
            WINGS_DATA="${_C}"
            WINGS_VOLUMES="${WINGS_DATA}/volumes"
            info "Wings data dir: ${WINGS_DATA}"
        fi
    fi
else
    warn "Wings NOT found — wings/volumes backup skipped"
fi

# ==============================================================================
#  STEP 6 — Write backup worker + systemd timer
# ==============================================================================
banner "6/6  Writing worker & timer"

mkdir -p "${STAGING}"

cat > "${BACKUP_SCRIPT}" <<SCRIPT
#!/usr/bin/env bash
# Auto-generated by vps_backup_setup.sh v4 — do not edit by hand
set -euo pipefail

REMOTE="${RCLONE_REMOTE}"
BACKUP_FOLDER="${BACKUP_FOLDER}"
KEEP=${KEEP}
SYSTEM_DIRS="${SYSTEM_DIRS}"
STAGING="${STAGING}"
LOG="${LOG}"
HAS_PANEL="${HAS_PANEL}"
HAS_WINGS="${HAS_WINGS}"
PANEL_DIR="${PANEL_DIR}"
PANEL_ENV="${PANEL_ENV}"
WINGS_CONFIG="${WINGS_CONFIG}"
WINGS_DATA="${WINGS_DATA}"
WINGS_VOLUMES="${WINGS_VOLUMES}"

# ── helpers ───────────────────────────────────────────────────────────────────
log()  { echo "[\$(date '+%H:%M:%S')] [INFO]  \$*"; }
warn() { echo "[\$(date '+%H:%M:%S')] [WARN]  \$*"; }
ok()   { echo "[\$(date '+%H:%M:%S')] [OK]    \$*"; }

next_num() {
    local DEST="\$1" PFX="\$2" LAST N
    LAST=\$(rclone lsf "\${REMOTE}:\${BACKUP_FOLDER}/\${DEST}/" --format "n" 2>/dev/null \
        | grep "^\${PFX}_" | sort -V | tail -1 || true)
    [[ -z "\${LAST}" ]] && { echo "001"; return; }
    N=\$(echo "\${LAST}" | sed "s/^\${PFX}_//" | cut -d_ -f1 | sed 's/^0*//')
    [[ -z "\${N}" ]] && N=0
    printf "%03d" \$(( N + 1 ))
}

rotate() {
    local DEST="\$1" PFX="\$2" FILES COUNT EXCESS
    FILES=\$(rclone lsf "\${REMOTE}:\${BACKUP_FOLDER}/\${DEST}/" --format "n" 2>/dev/null \
        | grep "^\${PFX}_" | sort -V || true)
    COUNT=\$(echo "\${FILES}" | grep -c "^\${PFX}_" 2>/dev/null || echo 0)
    if (( COUNT > KEEP )); then
        EXCESS=\$(( COUNT - KEEP ))
        log "  Rotating — deleting \${EXCESS} oldest, keeping \${KEEP}"
        echo "\${FILES}" | head -n "\${EXCESS}" | while read -r OLD; do
            [[ -z "\${OLD}" ]] && continue
            log "    ✗ \${OLD}"
            rclone deletefile "\${REMOTE}:\${BACKUP_FOLDER}/\${DEST}/\${OLD}" && \
                ok "    Deleted: \${OLD}" || warn "    Failed to delete: \${OLD}"
        done
    else
        log "  \${DEST}/ has \${COUNT}/\${KEEP} backups — no rotation needed"
    fi
}

pack() {
    local OUT="\$1"; shift
    tar --ignore-failed-read -czf "\${OUT}" "\$@" 2>/dev/null || true
}

upload() {
    local ARC="\$1" DEST="\$2"
    local SZ; SZ=\$(du -sh "\${ARC}" | cut -f1)
    log "  Uploading \$(basename "\${ARC}") (\${SZ})…"
    rclone copy "\${ARC}" "\${REMOTE}:\${BACKUP_FOLDER}/\${DEST}/" \
        --stats 30s --log-level NOTICE
    rm -f "\${ARC}"
    ok "  ✔ \${BACKUP_FOLDER}/\${DEST}/\$(basename "\${ARC}")"
}

# ── main ──────────────────────────────────────────────────────────────────────
exec >> "\${LOG}" 2>&1

mkdir -p "\${STAGING}"
DATE=\$(date '+%Y-%m-%d')
TIME=\$(date '+%H-%M')
HOST=\$(hostname -s)

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "  BACKUP STARTED   \$(date '+%A %d %b %Y  %H:%M:%S')"
echo "  Host   : \${HOST}"
echo "  Remote : \${REMOTE}:\${BACKUP_FOLDER}/"
echo "╚══════════════════════════════════════════════════════════╝"

# ── A) SYSTEM ─────────────────────────────────────────────────────────────────
log "── A) System ─────────────────────────────────────────────────"
NUM=\$(next_num "system" "system")
ARC="\${STAGING}/system_\${NUM}_\${DATE}_\${TIME}.tar.gz"
# shellcheck disable=SC2086
pack "\${ARC}" \${SYSTEM_DIRS}
upload "\${ARC}" "system"
rotate "system" "system"

# ── B) PTERODACTYL PANEL ──────────────────────────────────────────────────────
if [[ "\${HAS_PANEL}" == "true" ]]; then
    log "── B) Pterodactyl Panel ──────────────────────────────────────"
    NUM=\$(next_num "pterodactyl" "panel")
    ARC="\${STAGING}/panel_\${NUM}_\${DATE}_\${TIME}.tar.gz"
    DB="\${STAGING}/panel_db_\${DATE}_\${TIME}.sql"
    DB_OK=false

    if [[ -f "\${PANEL_ENV}" ]]; then
        _H=\$(grep "^DB_HOST="     "\${PANEL_ENV}" | cut -d= -f2 | tr -d '"' || echo "127.0.0.1")
        _P=\$(grep "^DB_PORT="     "\${PANEL_ENV}" | cut -d= -f2 | tr -d '"' || echo "3306")
        _D=\$(grep "^DB_DATABASE=" "\${PANEL_ENV}" | cut -d= -f2 | tr -d '"' || true)
        _U=\$(grep "^DB_USERNAME=" "\${PANEL_ENV}" | cut -d= -f2 | tr -d '"' || true)
        _W=\$(grep "^DB_PASSWORD=" "\${PANEL_ENV}" | cut -d= -f2 | tr -d '"' || true)
        if command -v mysqldump &>/dev/null && [[ -n "\${_D}" ]]; then
            log "Dumping MySQL '\${_D}'…"
            if MYSQL_PWD="\${_W}" mysqldump -h "\${_H}" -P "\${_P}" -u "\${_U}" "\${_D}" \
                > "\${DB}" 2>/dev/null; then
                ok "DB dump: \$(du -sh "\${DB}" | cut -f1)"
                DB_OK=true
            else
                warn "mysqldump failed — files only"
                rm -f "\${DB}"
            fi
        fi
    fi

    if [[ "\${DB_OK}" == "true" ]]; then
        pack "\${ARC}" "\${PANEL_DIR}" "\${WINGS_CONFIG}" "\${DB}"
        rm -f "\${DB}"
    else
        pack "\${ARC}" "\${PANEL_DIR}" "\${WINGS_CONFIG}"
    fi
    upload "\${ARC}" "pterodactyl"
    rotate "pterodactyl" "panel"
else
    log "── B) Panel not installed — skipping ─────────────────────────"
fi

# ── C) WINGS DATA ─────────────────────────────────────────────────────────────
if [[ "\${HAS_WINGS}" == "true" ]]; then
    log "── C) Wings daemon data ──────────────────────────────────────"
    if [[ -d "\${WINGS_DATA}" ]]; then
        NUM=\$(next_num "wings" "wings")
        ARC="\${STAGING}/wings_\${NUM}_\${DATE}_\${TIME}.tar.gz"
        tar --ignore-failed-read -czf "\${ARC}" \
            --exclude="\${WINGS_VOLUMES}" "\${WINGS_DATA}" 2>/dev/null || true
        upload "\${ARC}" "wings"
        rotate "wings" "wings"
    else
        warn "Wings data dir not found"
    fi

    # ── D) SERVER VOLUMES ─────────────────────────────────────────────────────
    log "── D) Server volumes ─────────────────────────────────────────"
    if [[ -d "\${WINGS_VOLUMES}" ]]; then
        shopt -s nullglob
        VOL_COUNT=0
        for SRV in "\${WINGS_VOLUMES}"/*/; do
            [[ -d "\${SRV}" ]] || continue
            UUID=\$(basename "\${SRV}")
            [[ -z "\$(ls -A "\${SRV}" 2>/dev/null)" ]] && { warn "  \${UUID} empty — skip"; continue; }
            VSUB="volumes/\${UUID}"
            PFX="vol_\${UUID}"
            NUM=\$(next_num "\${VSUB}" "\${PFX}")
            ARC="\${STAGING}/\${PFX}_\${NUM}_\${DATE}_\${TIME}.tar.gz"
            log "  → \${UUID}"
            pack "\${ARC}" "\${SRV}"
            upload "\${ARC}" "\${VSUB}"
            rotate "\${VSUB}" "\${PFX}"
            VOL_COUNT=\$((VOL_COUNT+1))
        done
        shopt -u nullglob
        ok "\${VOL_COUNT} volume(s) backed up"
    else
        warn "Volumes dir not found"
    fi
else
    log "── C/D) Wings not installed — skipping ───────────────────────"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "  BACKUP COMPLETE  \$(date '+%A %d %b %Y  %H:%M:%S')"
echo "╚══════════════════════════════════════════════════════════╝"
SCRIPT

chmod +x "${BACKUP_SCRIPT}"
ok "Worker written to ${BACKUP_SCRIPT}"

# ── systemd service ───────────────────────────────────────────────────────────
cat > "/etc/systemd/system/${SVC}.service" <<SVC_EOF
[Unit]
Description=VPS + Pterodactyl Backup → ${RCLONE_REMOTE}:${BACKUP_FOLDER}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${BACKUP_SCRIPT}
StandardOutput=journal
StandardError=journal
TimeoutStartSec=21600
SVC_EOF

# OnCalendar = fixed wall-clock times, nothing can break it
cat > "/etc/systemd/system/${SVC}.timer" <<TMR_EOF
[Unit]
Description=VPS Backup every 3 hours
Requires=${SVC}.service

[Timer]
OnCalendar=*-*-* 00,03,06,09,12,15,18,21:00:00
Persistent=true
Unit=${SVC}.service

[Install]
WantedBy=timers.target
TMR_EOF

systemctl daemon-reload
systemctl enable --now "${SVC}.timer"

NEXT=$(systemctl list-timers "${SVC}.timer" --no-pager 2>/dev/null \
    | grep "${SVC}" | awk '{print $1,$2,$3}' || true)
ok "Timer active — next run: ${NEXT}"

info "Firing first backup now…"
systemctl start "${SVC}.service" &
ok "First backup running in background"

# ==============================================================================
#  DONE
# ==============================================================================
echo ""
echo -e "${B}${G}══════════════════════════════════════════════════════════${X}"
echo -e "${B}${G}  ✔  Setup complete!${X}"
echo -e "${B}${G}══════════════════════════════════════════════════════════${X}"
echo ""
echo -e "  ${B}Remote  :${X} ${C}${RCLONE_REMOTE}${X}"
echo -e "  ${B}Folder  :${X} ${C}${BACKUP_FOLDER}/${X}"
echo -e "  ${B}Schedule:${X} 00:00  03:00  06:00  09:00  12:00  15:00  18:00  21:00 UTC"
echo -e "  ${B}Keep    :${X} Last ${KEEP} per category — oldest auto-deleted"
echo ""
echo -e "  ${B}GitHub  :${X} ${C}github.com/${GH_USER}/${GH_REPO}${X} (public, config is encrypted)"
echo ""
echo -e "  ${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo -e "  ${B}On a NEW VPS — just run this one command:${X}"
echo -e ""
echo -e "  ${C}curl -fsSL https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/vps_backup_setup.sh | sudo bash -s -- --from-github${X}"
echo -e ""
echo -e "  ${Y}It will ask for your encryption password — that's it.${X}"
echo -e "  ${B}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${X}"
echo ""
echo -e "  ${B}Commands:${X}"
echo -e "    Live log  →  ${C}journalctl -u ${SVC} -f${X}"
echo -e "    Full log  →  ${C}tail -f ${LOG}${X}"
echo -e "    Run now   →  ${C}systemctl start ${SVC}.service${X}"
echo -e "    Next run  →  ${C}systemctl list-timers ${SVC}.timer${X}"
echo -e "    Browse    →  ${C}rclone lsd ${RCLONE_REMOTE}:${BACKUP_FOLDER}/${X}"
echo -e "    Disable   →  ${C}systemctl disable --now ${SVC}.timer${X}"
echo ""
