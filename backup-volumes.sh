#!/usr/bin/env bash
# ==============================================================================
# DABV — Docker Automated Backup for Volumes
# Version: 1.0
# Platform: Debian / Ubuntu
# https://github.com/kayaman78/dabv
# ==============================================================================

# --- GENERAL SETTINGS ---
DRY_RUN="off"                              # [on/off] — set to "on" to simulate without writing anything
BACKUP_ROOT="/srv/docker/dabv/backups"      # Root directory where backups will be stored
RETENTION_DAYS=7                           # How many days to keep backups and logs
STOP_TIMEOUT=60                            # Seconds to wait for container stop before proceeding
SIZE_DROP_WARN=20                          # % size drop vs previous backup that triggers a warning

# --- VOLUME JOBS ---
# Format: "volume_name|container_name|stop_required"
#   volume_name     — exact Docker volume name (from: docker volume ls)
#   container_name  — container to stop/start if stop_required is "yes" (from: docker ps --format '{{.Names}}')
#                     use "none" if stop is not needed
#   stop_required   — "yes" to stop the container before backup, "no" to backup while running
#
# Examples:
#   "loki_data|loki-loki-1|yes"        # Loki writes actively — must stop
#   "grafana_data|monitoring-grafana-1|no"   # Grafana tolerates hot backup
#   "gitea_data|gitea-server-1|no"     # Static assets, safe hot
VOLUME_JOBS=(
    # "volume_name|container_name|stop_required"
)

# Volumes to skip even if listed above or found accidentally
# Example: EXCLUDED_VOLUMES=("postgres_data" "mysql_data")
# Tip: exclude any volume already covered by KDD (DB data directories)
EXCLUDED_VOLUMES=()

# --- SMTP SETTINGS ---
SMTP_SERVER="smtp.example.com"
SMTP_PORT="587"         # 25 = plain relay | 465 = SMTPS (immediate SSL) | 587 = STARTTLS
SMTP_USER=""            # Leave empty for unauthenticated relay
SMTP_PASS=""

# --- EMAIL SETTINGS ---
EMAIL_FROM="dabv@example.com"
EMAIL_TO="admin@example.com"
EMAIL_SUBJECT_PREFIX="Volume Backup"

# Telegram (optional)
TELEGRAM_ENABLED="false"
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""

# ntfy (optional)
NTFY_ENABLED="false"
NTFY_URL=""           # e.g. https://ntfy.sh or your self-hosted instance
NTFY_TOPIC=""         # e.g. dabv-backups

# Attach log to push notifications
NOTIFY_ATTACH_LOG="false"

# ==============================================================================
# INITIAL CHECKS
# ==============================================================================
[[ $EUID -ne 0 ]] && echo "Error: run as root or with sudo." && exit 1

LOG_DIR="$BACKUP_ROOT/log"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/backup-volumes_$(date +%Y%m%d).log"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

if ! command -v docker &>/dev/null; then
    echo "FATAL ERROR: 'docker' not found. Cannot continue." >&2
    exit 1
fi

# Auto-install missing dependencies (Debian/Ubuntu)
declare -A DEP_MAP=(
    [swaks]="swaks"
    [curl]="curl"
)

MISSING_PKGS=()
for cmd in "${!DEP_MAP[@]}"; do
    command -v "$cmd" &>/dev/null || MISSING_PKGS+=("${DEP_MAP[$cmd]}")
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "⚙️  Installing missing dependencies: ${MISSING_PKGS[*]}"
    apt-get update -qq && apt-get install -y -qq "${MISSING_PKGS[@]}"
fi

# ==============================================================================
# WORKING VARIABLES
# ==============================================================================
DATE_ID=$(date +%Y%m%d_%H%M%S)
DATE_LABEL=$(date "+%Y-%m-%d %H:%M")
HOSTNAME=$(hostname)

TABLE_ROWS=""
GLOBAL_STATUS="OK"
COUNT_OK=0
COUNT_ERR=0
COUNT_DRY=0
COUNT_VERIFY_OK=0
COUNT_VERIFY_WARN=0
COUNT_VERIFY_ERR=0

echo "============================================================"
echo "🚀 START Volume Backup: $(date) — Host: $HOSTNAME"
echo "Mode: $([ "$DRY_RUN" == "on" ] && echo "DRY-RUN (no backup will be written)" || echo "PRODUCTION")"
[ ${#EXCLUDED_VOLUMES[@]} -gt 0 ] && echo "Excluded volumes: ${EXCLUDED_VOLUMES[*]}"
echo "============================================================"

# ==============================================================================
# VERIFY FUNCTION
# Checks a freshly created .tar.gz backup:
#   1. gzip integrity
#   2. tar structure validity
#   3. Size comparison vs previous backup (warn if drop > SIZE_DROP_WARN%)
#
# Outputs: "OK" | "WARN:<reason>" | "FAIL:<reason>"
# ==============================================================================
verify_volume_backup() {
    local gz_file="$1"
    local dest_dir="$2"
    local vol_name="$3"
    local warn_msg=""

    # Check 1 — gzip integrity
    if ! gzip -t "$gz_file" 2>/dev/null; then
        echo "FAIL:gzip corrupt"
        return
    fi

    # Check 2 — tar structure
    if ! tar tzf "$gz_file" > /dev/null 2>&1; then
        echo "FAIL:tar structure invalid"
        return
    fi

    # Check 3 — size trend vs previous backup
    local curr_size
    curr_size=$(stat -c%s "$gz_file" 2>/dev/null || echo 0)

    local prev_file
    prev_file=$(find "$dest_dir" -name "dump-*.tar.gz" ! -newer "$gz_file" ! -samefile "$gz_file" \
        -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

    if [ -n "$prev_file" ] && [ -f "$prev_file" ]; then
        local prev_size
        prev_size=$(stat -c%s "$prev_file" 2>/dev/null || echo 0)
        if [ "$prev_size" -gt 0 ]; then
            local threshold=$(( prev_size * (100 - SIZE_DROP_WARN) / 100 ))
            if [ "$curr_size" -lt "$threshold" ]; then
                local curr_h prev_h
                curr_h=$(du -h "$gz_file"   | cut -f1)
                prev_h=$(du -h "$prev_file" | cut -f1)
                warn_msg="size drop ${prev_h}→${curr_h}"
            fi
        fi
    fi

    if [ -n "$warn_msg" ]; then
        echo "WARN:${warn_msg}"
    else
        echo "OK"
    fi
}

# ==============================================================================
# NOTIFICATION FUNCTIONS
# ==============================================================================
build_text_summary() {
    local icon="✅"
    [ $COUNT_ERR -gt 0 ]                                          && icon="❌"
    [ $COUNT_ERR -eq 0 ] && [ $COUNT_VERIFY_WARN -gt 0 ]         && icon="⚠️"
    [ $COUNT_VERIFY_ERR -gt 0 ]                                   && icon="❌"

    local total=$((COUNT_OK + COUNT_ERR))
    printf "%s DABV Backup — %s | %s\nVolumes %s✅ %s❌ (total: %s)\nVerify %s✅ %s⚠️ %s❌" \
        "$icon" "$HOSTNAME" "$DATE_LABEL" \
        "$COUNT_OK" "$COUNT_ERR" "$total" \
        "$COUNT_VERIFY_OK" "$COUNT_VERIFY_WARN" "$COUNT_VERIFY_ERR"
}

send_telegram() {
    [ "$TELEGRAM_ENABLED" != "true" ] && return 0
    if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_CHAT_ID" ]; then
        echo "⚠️  WARNING: Telegram enabled but TOKEN or CHAT_ID missing — skipping"
        return 1
    fi

    local text api
    text=$(build_text_summary)
    api="https://api.telegram.org/bot${TELEGRAM_TOKEN}"

    if [ "$NOTIFY_ATTACH_LOG" = "true" ] && [ -f "$LOG_FILE" ]; then
        curl -sf -X POST "${api}/sendDocument" \
            -F "chat_id=${TELEGRAM_CHAT_ID}" \
            -F "caption=${text}" \
            -F "document=@${LOG_FILE}" \
            > /dev/null 2>&1 \
            && echo "    📨 Telegram: sent with log attachment." \
            || echo "    ⚠️  WARNING: Telegram delivery failed."
    else
        curl -sf -X POST "${api}/sendMessage" \
            -H "Content-Type: application/json" \
            -d "{\"chat_id\":\"${TELEGRAM_CHAT_ID}\",\"text\":\"${text}\"}" \
            > /dev/null 2>&1 \
            && echo "    📨 Telegram: sent." \
            || echo "    ⚠️  WARNING: Telegram delivery failed."
    fi
}

send_ntfy() {
    [ "$NTFY_ENABLED" != "true" ] && return 0
    if [ -z "$NTFY_URL" ] || [ -z "$NTFY_TOPIC" ]; then
        echo "⚠️  WARNING: ntfy enabled but URL or TOPIC missing — skipping"
        return 1
    fi

    local text priority=3
    text=$(build_text_summary)
    { [ $COUNT_ERR -gt 0 ] || [ $COUNT_VERIFY_ERR -gt 0 ]; } && priority=5

    if [ "$NOTIFY_ATTACH_LOG" = "true" ] && [ -f "$LOG_FILE" ]; then
        curl -sf -X PUT "${NTFY_URL}/${NTFY_TOPIC}" \
            -H "Title: DABV Backup — ${HOSTNAME}" \
            -H "Priority: ${priority}" \
            -H "Filename: $(basename "$LOG_FILE")" \
            --data-binary "@${LOG_FILE}" \
            > /dev/null 2>&1 \
            && echo "    📨 ntfy: sent with log attachment." \
            || echo "    ⚠️  WARNING: ntfy delivery failed."
    else
        curl -sf -X POST "${NTFY_URL}/${NTFY_TOPIC}" \
            -H "Title: DABV Backup — ${HOSTNAME}" \
            -H "Priority: ${priority}" \
            -d "$text" \
            > /dev/null 2>&1 \
            && echo "    📨 ntfy: sent." \
            || echo "    ⚠️  WARNING: ntfy delivery failed."
    fi
}

# ==============================================================================
# HELPER — check if volume is excluded
# ==============================================================================
is_excluded() {
    local vol="$1"
    for excl in "${EXCLUDED_VOLUMES[@]}"; do
        [ "$vol" = "$excl" ] && return 0
    done
    return 1
}

# ==============================================================================
# MAIN — process each volume job
# ==============================================================================
if [ ${#VOLUME_JOBS[@]} -eq 0 ]; then
    echo "[!] No volume jobs configured. Add entries to VOLUME_JOBS and re-run."
    echo "    Tip: list available volumes with: docker volume ls"
fi

for job in "${VOLUME_JOBS[@]}"; do
    IFS='|' read -r VOL_NAME CONTAINER_NAME STOP_REQUIRED <<< "$job"

    # Strip whitespace
    VOL_NAME=$(echo "$VOL_NAME" | xargs)
    CONTAINER_NAME=$(echo "$CONTAINER_NAME" | xargs)
    STOP_REQUIRED=$(echo "$STOP_REQUIRED" | xargs)

    echo ""
    echo "[*] 🗄️  Volume: $VOL_NAME"

    # Check exclusion
    if is_excluded "$VOL_NAME"; then
        echo "    ⏭️  Skipped (excluded)"
        continue
    fi

    # Verify volume exists
    if ! docker volume inspect "$VOL_NAME" > /dev/null 2>&1; then
        echo "    ❌ ERROR: Volume '$VOL_NAME' not found — skipping"
        COUNT_ERR=$((COUNT_ERR + 1))
        GLOBAL_STATUS="ERROR"
        TABLE_ROWS+="<tr>
            <td style='padding:8px;border:1px solid #ddd;'>${VOL_NAME}</td>
            <td style='padding:8px;border:1px solid #ddd;'>${CONTAINER_NAME}</td>
            <td style='padding:8px;border:1px solid #ddd;'>—</td>
            <td style='padding:8px;border:1px solid #ddd;text-align:center;'>❌ not found</td>
            <td style='padding:8px;border:1px solid #ddd;text-align:center;'>—</td>
        </tr>"
        continue
    fi

    # Dry run shortcut
    if [ "$DRY_RUN" == "on" ]; then
        echo "    [DRY-RUN] Would backup volume: $VOL_NAME (stop: $STOP_REQUIRED)"
        COUNT_DRY=$((COUNT_DRY + 1))
        TABLE_ROWS+="<tr>
            <td style='padding:8px;border:1px solid #ddd;'>${VOL_NAME}</td>
            <td style='padding:8px;border:1px solid #ddd;'>${CONTAINER_NAME}</td>
            <td style='padding:8px;border:1px solid #ddd;'>—</td>
            <td style='padding:8px;border:1px solid #ddd;text-align:center;'>⏭️ dry-run</td>
            <td style='padding:8px;border:1px solid #ddd;text-align:center;'>—</td>
        </tr>"
        continue
    fi

    # Prepare destination
    DEST_DIR="$BACKUP_ROOT/$VOL_NAME"
    mkdir -p "$DEST_DIR"
    DEST_FILE="$DEST_DIR/dump-${DATE_ID}.tar.gz"

    # Stop container if required
    CONTAINER_WAS_RUNNING=false
    if [ "$STOP_REQUIRED" = "yes" ] && [ "$CONTAINER_NAME" != "none" ]; then
        if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
            echo "    ⏸️  Stopping $CONTAINER_NAME..."
            docker stop --time="$STOP_TIMEOUT" "$CONTAINER_NAME" > /dev/null 2>&1
            CONTAINER_WAS_RUNNING=true
        else
            echo "    ⚠️  Container '$CONTAINER_NAME' not running — proceeding anyway"
        fi
    fi

    # Backup via alpine container
    echo "    📦 Backing up: $VOL_NAME"
    BACKUP_OK=false

    if docker run --rm \
        -v "${VOL_NAME}:/source:ro" \
        -v "${DEST_DIR}:/backup" \
        alpine \
        tar czf "/backup/$(basename "$DEST_FILE")" -C /source . 2>/dev/null; then
        BACKUP_OK=true
        BACKUP_SIZE=$(du -h "$DEST_FILE" | cut -f1)
        echo "    ✅ Backup OK: $BACKUP_SIZE"
    else
        echo "    ❌ ERROR: backup failed for $VOL_NAME"
        COUNT_ERR=$((COUNT_ERR + 1))
        GLOBAL_STATUS="ERROR"
    fi

    # Restart container if we stopped it
    if [ "$CONTAINER_WAS_RUNNING" = true ]; then
        echo "    ▶️  Starting $CONTAINER_NAME..."
        docker start "$CONTAINER_NAME" > /dev/null 2>&1
    fi

    # Verify
    VERIFY_RESULT="—"
    VERIFY_COLOR="#888"
    if [ "$BACKUP_OK" = true ]; then
        echo "    🔍 Verifying: $VOL_NAME"
        VERIFY_RESULT=$(verify_volume_backup "$DEST_FILE" "$DEST_DIR" "$VOL_NAME")

        case "$VERIFY_RESULT" in
            OK)
                echo "    ✅ Verify OK"
                COUNT_OK=$((COUNT_OK + 1))
                COUNT_VERIFY_OK=$((COUNT_VERIFY_OK + 1))
                VERIFY_COLOR="#2e7d32"
                ;;
            WARN:*)
                VERIFY_DETAIL="${VERIFY_RESULT#WARN:}"
                echo "    ⚠️  Verify WARN: $VERIFY_DETAIL"
                COUNT_OK=$((COUNT_OK + 1))
                COUNT_VERIFY_WARN=$((COUNT_VERIFY_WARN + 1))
                [ "$GLOBAL_STATUS" = "OK" ] && GLOBAL_STATUS="WARN"
                VERIFY_COLOR="#e65100"
                VERIFY_RESULT="⚠️ $VERIFY_DETAIL"
                ;;
            FAIL:*)
                VERIFY_DETAIL="${VERIFY_RESULT#FAIL:}"
                echo "    ❌ Verify FAIL: $VERIFY_DETAIL"
                COUNT_ERR=$((COUNT_ERR + 1))
                COUNT_VERIFY_ERR=$((COUNT_VERIFY_ERR + 1))
                GLOBAL_STATUS="ERROR"
                VERIFY_COLOR="#c62828"
                VERIFY_RESULT="❌ $VERIFY_DETAIL"
                ;;
        esac
    else
        VERIFY_RESULT="skipped"
    fi

    # Table row
    STOP_LABEL=$([ "$STOP_REQUIRED" = "yes" ] && echo "⏸️ stopped" || echo "🔄 hot")
    BACKUP_CELL=$([ "$BACKUP_OK" = true ] && echo "✅ $BACKUP_SIZE" || echo "❌ failed")
    TABLE_ROWS+="<tr>
        <td style='padding:8px;border:1px solid #ddd;'>${VOL_NAME}</td>
        <td style='padding:8px;border:1px solid #ddd;font-size:12px;color:#666;'>${STOP_LABEL}</td>
        <td style='padding:8px;border:1px solid #ddd;'>${BACKUP_SIZE:-—}</td>
        <td style='padding:8px;border:1px solid #ddd;text-align:center;'>${BACKUP_CELL}</td>
        <td style='padding:8px;border:1px solid #ddd;text-align:center;color:${VERIFY_COLOR};'>${VERIFY_RESULT}</td>
    </tr>"
done

# ==============================================================================
# RETENTION
# ==============================================================================
echo ""
echo "🧹 Removing backups older than $RETENTION_DAYS days..."

DELETED_COUNT=0
while IFS= read -r -d '' old_file; do
    echo "    Removing: $old_file"
    rm -f "$old_file"
    ((DELETED_COUNT++))
done < <(
    find "$BACKUP_ROOT" -type f -name "*.tar.gz" \
        -not -path "*/log/*" \
        -mtime +"$((RETENTION_DAYS - 1))" -print0
)
echo "    Removed $DELETED_COUNT file(s)."

find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -not -name "log" -empty -delete

echo "🧹 Removing logs older than $RETENTION_DAYS days..."
DELETED_LOGS=0
while IFS= read -r -d '' old_log; do
    echo "    Removing log: $old_log"
    rm -f "$old_log"
    ((DELETED_LOGS++))
done < <(
    find "$LOG_DIR" -type f -name "*.log" \
        -mtime +"$((RETENTION_DAYS - 1))" -print0
)
echo "    Removed $DELETED_LOGS log(s)."

# ==============================================================================
# BUILD EMAIL
# ==============================================================================
case "$GLOBAL_STATUS" in
    OK)    STATUS_ICON="✅" ;;
    WARN)  STATUS_ICON="⚠️" ;;
    ERROR) STATUS_ICON="❌" ;;
    *)     STATUS_ICON="⚠️" ;;
esac

if [ "$DRY_RUN" == "on" ]; then
    EMAIL_SUBJECT="[DRY-RUN ⚠️] ${EMAIL_SUBJECT_PREFIX} | ${HOSTNAME} | ${DATE_LABEL}"
else
    EMAIL_SUBJECT="[${STATUS_ICON} ${GLOBAL_STATUS}] ${EMAIL_SUBJECT_PREFIX} | ${HOSTNAME} | ${DATE_LABEL}"
fi

if [ "$DRY_RUN" == "off" ]; then
    TOTAL=$((COUNT_OK + COUNT_ERR))
    SUMMARY_LINE="Volumes: <b>${TOTAL}</b> &nbsp;|&nbsp; Backup ✅ <b>${COUNT_OK}</b> ❌ <b>${COUNT_ERR}</b>"
    SUMMARY_LINE+="<br>Verify ✅ <b>${COUNT_VERIFY_OK}</b> ⚠️ <b>${COUNT_VERIFY_WARN}</b> ❌ <b>${COUNT_VERIFY_ERR}</b>"
    [ $DELETED_COUNT -gt 0 ] && SUMMARY_LINE+="<br>Backups removed by retention: <b>${DELETED_COUNT}</b>"
    [ $DELETED_LOGS -gt 0 ]  && SUMMARY_LINE+="<br>Logs removed by retention: <b>${DELETED_LOGS}</b>"
else
    SUMMARY_LINE="Mode: <b>DRY-RUN</b> — <b>${COUNT_DRY}</b> volume(s) found. No backup written, no filesystem changes."
fi

EXCLUSIONS_LINE=""
[ ${#EXCLUDED_VOLUMES[@]} -gt 0 ] && EXCLUSIONS_LINE="<br><strong>Excluded volumes:</strong> ${EXCLUDED_VOLUMES[*]}"

if [ -z "$TABLE_ROWS" ]; then
    TABLE_ROWS="<tr><td colspan='5' style='padding: 12px; text-align:center; color:#888;'>No volume jobs configured.</td></tr>"
fi

HTML_BODY="<html>
<body style='font-family: Arial, sans-serif; color: #333; max-width: 750px; margin: 0 auto;'>

<h2 style='border-bottom: 2px solid #eee; padding-bottom: 8px;'>${EMAIL_SUBJECT_PREFIX}</h2>

<p style='font-size: 14px;'>
    <strong>Server:</strong> ${HOSTNAME}<br>
    <strong>Date:</strong> ${DATE_LABEL}<br>
    <strong>Global status:</strong> ${STATUS_ICON} <b>${GLOBAL_STATUS}</b>${EXCLUSIONS_LINE}
</p>

<p style='background: #f9f9f9; border-left: 4px solid #ccc; padding: 10px 14px; font-size: 13px;'>
    ${SUMMARY_LINE}
</p>

<table style='width: 100%; border-collapse: collapse; margin-top: 16px; font-size: 13px;'>
    <thead>
        <tr style='background-color: #f2f2f2;'>
            <th style='padding: 9px 8px; border: 1px solid #ddd; text-align:left;'>Volume</th>
            <th style='padding: 9px 8px; border: 1px solid #ddd; text-align:left;'>Mode</th>
            <th style='padding: 9px 8px; border: 1px solid #ddd; text-align:left;'>Size</th>
            <th style='padding: 9px 8px; border: 1px solid #ddd; text-align:center;'>Backup</th>
            <th style='padding: 9px 8px; border: 1px solid #ddd; text-align:center;'>Verify</th>
        </tr>
    </thead>
    <tbody>
        ${TABLE_ROWS}
    </tbody>
</table>

<p style='font-size: 11px; color: #aaa; margin-top: 24px;'>
    Log: ${LOG_FILE}<br>
    Retention: ${RETENTION_DAYS} days &nbsp;|&nbsp; Backups at: ${BACKUP_ROOT}<br>
    Verify: gzip integrity + tar structure + size trend (warn if drop &gt; ${SIZE_DROP_WARN}%)
</p>

</body>
</html>"

# ==============================================================================
# SEND EMAIL VIA SWAKS
# ==============================================================================
case "$SMTP_PORT" in
    465) SWAKS_TLS="--tls-on-connect" ;;
    587) SWAKS_TLS="--tls" ;;
    *)   SWAKS_TLS="" ;;
esac

SWAKS_AUTH=()
[[ -n "$SMTP_USER" ]] && SWAKS_AUTH=(--auth-user "$SMTP_USER" --auth-password "$SMTP_PASS")

echo ""
echo "[*] Sending report to $EMAIL_TO..."

swaks \
    --to      "$EMAIL_TO" \
    --from    "$EMAIL_FROM" \
    --server  "$SMTP_SERVER" \
    --port    "$SMTP_PORT" \
    $SWAKS_TLS \
    "${SWAKS_AUTH[@]}" \
    --header  "Subject: $EMAIL_SUBJECT" \
    --header  "Content-Type: text/html; charset=UTF-8" \
    --body    "$HTML_BODY" \
    > /dev/null 2>&1 \
    && echo "    Report sent." \
    || echo "    WARNING: email delivery failed (check SMTP settings)."

echo ""
echo "[*] 📣 Sending push notifications..."
send_telegram
send_ntfy

echo ""
echo "============================================================"
echo "END Volume Backup: $(date)"
echo "============================================================"