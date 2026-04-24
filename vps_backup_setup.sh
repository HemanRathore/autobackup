#!/usr/bin/env bash
# ==============================================================================
#  VPS + PTERODACTYL BACKUP SETUP  v5
#
#  ✔ Works when piped through curl (no TTY issue)
#  ✔ Timer uses OnCalendar — fires every 3h reliably
#  ✔ Keeps last 2 backups, oldest auto-deleted correctly
#  ✔ GitHub (PUBLIC repo) + AES-256 encrypted rclone config
#
#  FIRST TIME (download and run directly):
#    curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/vps_backup_setup.sh -o setup.sh
#    sudo bash setup.sh
#
#  NEW VPS (after first time setup):
#    curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/vps_backup_setup.sh -o setup.sh
#    sudo bash setup.sh --from-github
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

GH_ENCRYPTED_CONF="backup-config/rclone.conf.enc"
GH_SETTINGS="backup-config/settings.conf"
GH_SCRIPT="vps_backup_setup.sh"

FROM_GITHUB=false
[[ "${1:-}" == "--from-github" ]] && FROM_GITHUB=true

# ── TTY-safe read helper ──────────────────────────────────────────────────────
# When script is piped through curl, stdin is the pipe not the terminal.
# We force reads from /dev/tty so interactive prompts always work.
ask() {
    # ask <varname> <prompt> [default]
    local _VAR="$1" _PROMPT="$2" _DEFAULT="${3:-}" _VAL
    printf "%s" "${_PROMPT}" > /dev/tty
    read -r _VAL < /dev/tty
    _VAL="${_VAL:-${_DEFAULT}}"
    printf -v "${_VAR}" '%s' "${_VAL}"
}

ask_secret() {
    # ask_secret <varname> <prompt>
    local _VAR="$1" _PROMPT="$2" _VAL
    printf "%s" "${_PROMPT}" > /dev/tty
    read -rs _VAL < /dev/tty
    echo "" > /dev/tty
    printf -v "${_VAR}" '%s' "${_VAL}"
}

# ==============================================================================
#  STEP 1 — Install dependencies
# ==============================================================================
banner "1/6  Installing dependencies"

if command -v rclone &>/dev/null; then
    ok "rclone $(rclone version | head -1 | awk '{print $2}')"
else
    info "Installing rclone…"
    curl -fsSL https://rclone.org/install.sh | bash
    ok "rclone installed"
fi

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
#  STEP 2 — GitHub repo details
# ==============================================================================
banner "2/6  GitHub setup"

if [[ "${FROM_GITHUB}" == "true" ]]; then
    # Pull GH_USER and GH_REPO from the baked-in settings if available
    if [[ -f "${CONF_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONF_FILE}"
        ok "Loaded saved settings — ${GH_USER}/${GH_REPO}"
    else
        # Ask from /dev/tty (works even with curl pipe)
        echo -e "  Enter your GitHub details to pull your config." > /dev/tty
        ask GH_USER "  GitHub username: "
        ask GH_REPO "  Repo name [vps-backup-config]: " "vps-backup-config"
    fi
else
    echo -e "  Your rclone config will be ${B}AES-256 encrypted${X} and pushed to a public GitHub repo." > /dev/tty
    echo -e "  Nobody can use the encrypted file without your password.\n" > /dev/tty
    ask GH_USER "  GitHub username: "
    ask GH_REPO "  Repo name [vps-backup-config]: " "vps-backup-config"
fi

GH_RAW="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main"
GH_API="https://api.github.com"

if [[ "${FROM_GITHUB}" == "false" ]]; then
    HTTP=$(curl -s -o /dev/null -w "%{http_code}" "${GH_API}/repos/${GH_USER}/${GH_REPO}")
    if [[ "${HTTP}" == "200" ]]; then
        ok "Repo found: github.com/${GH_USER}/${GH_REPO}"
    elif [[ "${HTTP}" == "404" ]]; then
        echo -e "\n  ${Y}Repo '${GH_REPO}' not found.${X}" > /dev/tty
        echo -e "  Create it at: ${C}https://github.com/new${X}" > /dev/tty
        echo -e "  → Name: ${B}${GH_REPO}${X}  → Public  → Tick 'Add README'\n" > /dev/tty
        ask _DUMMY "  Press ENTER once the repo is created…"
        HTTP2=$(curl -s -o /dev/null -w "%{http_code}" "${GH_API}/repos/${GH_USER}/${GH_REPO}")
        [[ "${HTTP2}" == "200" ]] || die "Repo still not found. Check name and try again."
        ok "Repo confirmed."
    else
        die "GitHub returned HTTP ${HTTP}. Check your username and internet."
    fi
fi

# ==============================================================================
#  STEP 3 — Encryption password
# ==============================================================================
banner "3/6  Encryption password"

echo -e "  This password encrypts your rclone config stored on GitHub." > /dev/tty
echo -e "  ${B}Remember it — you need it on every new VPS. No recovery possible.${X}\n" > /dev/tty

if [[ "${FROM_GITHUB}" == "true" ]]; then
    # Only ask once — we're just decrypting
    ask_secret ENC_PASS "  Enter your encryption password: "
    [[ -z "${ENC_PASS}" ]] && die "Password cannot be empty."
    ok "Password received"
else
    # Ask twice to confirm
    while true; do
        ask_secret ENC_PASS  "  Enter encryption password:   "
        ask_secret ENC_PASS2 "  Confirm encryption password: "
        if [[ "${ENC_PASS}" == "${ENC_PASS2}" ]]; then
            [[ -z "${ENC_PASS}" ]] && { warn "Password cannot be empty."; continue; }
            break
        fi
        warn "Passwords do not match — try again."
    done
    ok "Password set"
fi

# ── encryption helpers ────────────────────────────────────────────────────────
encrypt_file() { openssl enc -aes-256-cbc -pbkdf2 -iter 100000 -in "$1" -out "$2" -k "${ENC_PASS}"; }
decrypt_file() { openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 -in "$1" -out "$2" -k "${ENC_PASS}"; }

# ── git push helper ───────────────────────────────────────────────────────────
push_to_github() {
    local FILE_PATH="$1" REPO_PATH="$2" MSG="$3"
    local TMP_REPO="/tmp/gh-backup-repo-$$"
    rm -rf "${TMP_REPO}"

    # Try SSH key first
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -T git@github.com 2>&1 | grep -q "successfully authenticated"; then
        git clone "git@github.com:${GH_USER}/${GH_REPO}.git" "${TMP_REPO}" -q 2>/dev/null
    else
        echo -e "\n  ${Y}A one-time write token is needed to push to GitHub.${X}" > /dev/tty
        echo -e "  Create one at: ${C}https://github.com/settings/tokens/new${X}" > /dev/tty
        echo -e "  Scopes needed: tick ${B}repo${X} only. Expiry: No expiration.\n" > /dev/tty
        ask_secret GH_WRITE_TOKEN "  Paste token: "
        git clone "https://${GH_USER}:${GH_WRITE_TOKEN}@github.com/${GH_USER}/${GH_REPO}.git" \
            "${TMP_REPO}" -q 2>/dev/null
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
    unset GH_WRITE_TOKEN 2>/dev/null || true
}

# ==============================================================================
#  STEP 4 — rclone remote
# ==============================================================================
banner "4/6  rclone remote"

mkdir -p "$(dirname "${RCLONE_CONF}")"

if [[ "${FROM_GITHUB}" == "true" ]]; then
    info "Downloading encrypted rclone config from GitHub…"
    ENC_TMP=$(mktemp)
    if ! curl -fsSL "${GH_RAW}/${GH_ENCRYPTED_CONF}" -o "${ENC_TMP}" 2>/dev/null; then
        rm -f "${ENC_TMP}"
        die "Could not download encrypted config from GitHub. Check repo name and username."
    fi

    info "Decrypting rclone config…"
    if ! decrypt_file "${ENC_TMP}" "${RCLONE_CONF}" 2>/dev/null; then
        rm -f "${ENC_TMP}"
        die "Decryption failed — wrong password?"
    fi
    rm -f "${ENC_TMP}"
    chmod 600 "${RCLONE_CONF}"
    ok "rclone config restored"

    info "Loading settings from GitHub…"
    curl -fsSL "${GH_RAW}/${GH_SETTINGS}" -o "${CONF_FILE}" 2>/dev/null \
        || die "Could not download settings from GitHub."
    # shellcheck disable=SC1090
    source "${CONF_FILE}"
    ok "Settings loaded — Remote: ${RCLONE_REMOTE}  Folder: ${BACKUP_FOLDER}"

else
    # ── Fresh rclone setup ────────────────────────────────────────────────────
    EXISTING=$(rclone listremotes 2>/dev/null || true)

    if [[ -n "${EXISTING}" ]]; then
        echo -e "\n  ${G}Existing remotes:${X}" > /dev/tty
        echo "${EXISTING}" | while read -r RM; do echo -e "    ${C}${RM}${X}" > /dev/tty; done
        echo "" > /dev/tty
        ask USE_EX "  Use existing [u] or configure new [n]: "
        USE_EX="${USE_EX,,}"
    else
        USE_EX="n"
    fi

    if [[ "${USE_EX}" == "u" ]]; then
        ask RCLONE_REMOTE "  Remote name (without colon): "
        RCLONE_REMOTE="${RCLONE_REMOTE%:}"
        rclone listremotes | grep -q "^${RCLONE_REMOTE}:" || die "Remote not found."
        ok "Using: ${RCLONE_REMOTE}"
    else
        echo -e "${Y}" > /dev/tty
        cat <<MSG > /dev/tty
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
        echo -e "${X}" > /dev/tty
        ask _DUMMY "  Press ENTER to open rclone config…"
        BEFORE=$(rclone listremotes 2>/dev/null || true)
        rclone config
        AFTER=$(rclone listremotes 2>/dev/null || true)
        ADDED=$(comm -13 <(echo "${BEFORE}" | sort) <(echo "${AFTER}" | sort) || true)

        if [[ -n "${ADDED}" ]]; then
            RCLONE_REMOTE="${ADDED%%:*}"
            ok "Auto-detected remote: ${B}${RCLONE_REMOTE}${X}"
        else
            ask RCLONE_REMOTE "  Type the remote name you just created (without colon): "
            RCLONE_REMOTE="${RCLONE_REMOTE%:}"
        fi
        rclone listremotes | grep -q "^${RCLONE_REMOTE}:" || die "Remote not found."
    fi

    echo "" > /dev/tty
    echo -e "  ${B}Top-level folder name in your Google Drive:${X}" > /dev/tty
    ask BACKUP_FOLDER "  Press ENTER for [${RCLONE_REMOTE}-backups] or type custom: " "${RCLONE_REMOTE}-backups"
    BACKUP_FOLDER="${BACKUP_FOLDER// /-}"
    ok "Backup folder: ${B}${BACKUP_FOLDER}${X}"

    # Save settings
    cat > "${CONF_FILE}" <<CONF
RCLONE_REMOTE="${RCLONE_REMOTE}"
BACKUP_FOLDER="${BACKUP_FOLDER}"
GH_USER="${GH_USER}"
GH_REPO="${GH_REPO}"
CONF

    # Encrypt and push rclone config
    info "Encrypting rclone config…"
    ENC_TMP=$(mktemp)
    encrypt_file "${RCLONE_CONF}" "${ENC_TMP}"
    ok "Encrypted ($(du -sh "${ENC_TMP}" | cut -f1))"

    info "Pushing encrypted config to GitHub…"
    push_to_github "${ENC_TMP}" "${GH_ENCRYPTED_CONF}" "Update encrypted rclone config"
    rm -f "${ENC_TMP}"
    ok "Config pushed"

    info "Pushing settings to GitHub…"
    push_to_github "${CONF_FILE}" "${GH_SETTINGS}" "Update settings"
    ok "Settings pushed"

    info "Pushing setup script to GitHub…"
    # Script was saved to a temp file since we came through curl
    SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
    if [[ -f "${SCRIPT_PATH}" ]]; then
        push_to_github "${SCRIPT_PATH}" "${GH_SCRIPT}" "Update setup script"
        ok "Setup script pushed"
    else
        warn "Cannot push setup script (piped from curl — download and push manually)"
    fi
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
# Auto-generated by vps_backup_setup.sh v5 — do not edit by hand
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
            rclone deletefile "\${REMOTE}:\${BACKUP_FOLDER}/\${DEST}/\${OLD}" \
                && ok "  ✗ Deleted: \${OLD}" \
                || warn "  Failed to delete: \${OLD}"
        done
    else
        log "  \${DEST}/ — \${COUNT}/\${KEEP} backups, no rotation needed"
    fi
}

pack()   { local OUT="\$1"; shift; tar --ignore-failed-read -czf "\${OUT}" "\$@" 2>/dev/null || true; }

upload() {
    local ARC="\$1" DEST="\$2"
    log "  Uploading \$(basename "\${ARC}") (\$(du -sh "\${ARC}" | cut -f1))…"
    rclone copy "\${ARC}" "\${REMOTE}:\${BACKUP_FOLDER}/\${DEST}/" --stats 30s --log-level NOTICE
    rm -f "\${ARC}"
    ok "  ✔ \${BACKUP_FOLDER}/\${DEST}/\$(basename "\${ARC}")"
}

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
        tar --ignore-failed-read -czf "\${ARC}" --exclude="\${WINGS_VOLUMES}" "\${WINGS_DATA}" 2>/dev/null || true
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

# ── systemd ───────────────────────────────────────────────────────────────────
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
echo -e "  ${B}GitHub  :${X} ${C}github.com/${GH_USER}/${GH_REPO}${X}"
echo ""
echo -e "  ${B}━━━━━━  On any NEW VPS — just run: ━━━━━━${X}"
echo ""
echo -e "  ${C}curl -fsSL https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/main/vps_backup_setup.sh -o setup.sh && sudo bash setup.sh --from-github${X}"
echo ""
echo -e "  ${Y}It will ask for your encryption password — that's it.${X}"
echo ""
echo -e "  ${B}Commands:${X}"
echo -e "    Live log  →  ${C}journalctl -u ${SVC} -f${X}"
echo -e "    Full log  →  ${C}tail -f ${LOG}${X}"
echo -e "    Run now   →  ${C}systemctl start ${SVC}.service${X}"
echo -e "    Next run  →  ${C}systemctl list-timers ${SVC}.timer${X}"
echo -e "    Browse    →  ${C}rclone lsd ${RCLONE_REMOTE}:${BACKUP_FOLDER}/${X}"
echo -e "    Disable   →  ${C}systemctl disable --now ${SVC}.timer${X}"
echo ""
