#!/bin/bash

# 🐾 Meet PantiMal
#     .-"      "-.
#    /            \
#   |   WP Anti-   |
#   |   Malware!   |
#   \___  🩲  ___/
#       \ (o_o) /
#        ( (_) )
#      __/`---'\__    - Watching your docroots so you don't have to.


# ========================= CONFIG (edit these) =========================
# Or copy pantimal.conf.example to /etc/pantimal.conf or ./pantimal.conf
# Alert destination. Empty = no mail. Override with --alert-email=addr
ALERT_EMAIL=""

# Default tree to walk. /var/www/clients covers ISPConfig client1/2/3/4.
BASE_DIR="/var/www/clients"
DOCROOT_NAME="web"

# Only snippets that carry this exact tag are treated as yours.
# Empty = do not enforce snippet ownership.
# Example: SNIPPET_OWNER_MARK="CTS-SNIPPET-OWNER:randell"
# Put the mark in the snippet name, description, or a code comment:
#   /* CTS-SNIPPET-OWNER:randell */
SNIPPET_OWNER_MARK=""

# Must-use plugins that are allowed to exist (see mu-plugins/).
ALLOWED_MU_PLUGINS=("guard-users.php" "disable-rest-api.php")

# Where quarantined files are moved (not deleted).
QUARANTINE_BASE="/var/log/pantimal-quarantine"

LOCK_FILE="/var/lock/pantimal.lock"
# ======================================================================

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
[[ -f /etc/pantimal.conf ]] && . /etc/pantimal.conf
# shellcheck disable=SC1091
[[ -f "${_SCRIPT_DIR}/pantimal.conf" ]] && . "${_SCRIPT_DIR}/pantimal.conf"

NO_SYMLINKS=false
LOG_FILE=""
APPEND_MODE=false
REPAIR_MODE=false
DRY_RUN=false
FORCE_REINSTALL=false
TIDY_MODE=false
SINGLE_DOCROOT=""
SEND_MAIL=true
WP_BIN="wp"
WP_CLI=""

ALERTS=()
QUARANTINED=0

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"
}

log_only() {
    echo "[$(timestamp)] $*" >> "$LOG_FILE"
}

alert() {
    local msg="$*"
    log "[ALERT] $msg"
    ALERTS+=("$msg")
}

print_help() {
    cat <<EOF
Usage: $0 [options]

Options:
  --repair              reinstall core if checksums fail; reinstall active plugins/themes
  --force               reinstall core for every site without verifying first
  --dry-run             print actions without making changes
  --append              append to the log instead of overwriting it
  --log-file=FILE       log path (default: /var/log/wp-check.log)
  --wp-cli=PATH         WP-CLI binary
  --tidy                remove inactive themes/plugins (keeps one default theme)
  --base-dir=DIR        site parent (default: /var/www/clients)
  --docroot=DIR         docroot folder name (default: web)
  --single-docroot=DIR  scan only this docroot
  --no-symlinks         skip symlink site directories
  --alert-email=ADDR    override ALERT_EMAIL (currently ${ALERT_EMAIL})
  --no-mail             do not send the alert digest
  --help                show this help

Default cron should be scan + quarantine only (no --repair / --tidy).

Code Snippets: only rows containing ${SNIPPET_OWNER_MARK} stay active.
EOF
}

for arg in "$@"; do
    case $arg in
        --repair) REPAIR_MODE=true ;;
        --dry-run) DRY_RUN=true ;;
        --force) FORCE_REINSTALL=true ;;
        --append) APPEND_MODE=true ;;
        --log-file=*) LOG_FILE="${arg#*=}" ;;
        --wp-cli=*) WP_BIN="${arg#*=}" ;;
        --base-dir=*) BASE_DIR="${arg#*=}" ;;
        --docroot=*) DOCROOT_NAME="${arg#*=}" ;;
        --single-docroot=*) SINGLE_DOCROOT="${arg#*=}" ;;
        --no-symlinks) NO_SYMLINKS=true ;;
        --tidy) TIDY_MODE=true ;;
        --alert-email=*) ALERT_EMAIL="${arg#*=}" ;;
        --no-mail) SEND_MAIL=false ;;
        --help) print_help; exit 0 ;;
    esac
done

WP_CLI="$WP_BIN --skip-plugins --skip-themes --allow-root"

if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="/var/log/wp-check.log"
fi

# Single-instance lock for cron
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    echo "PantiMal is already running; exiting."
    exit 0
fi

if $APPEND_MODE; then
    log_only "Starting PantiMal scan..."
else
    echo "[$(timestamp)] Starting PantiMal scan..." > "$LOG_FILE"
fi
log_only "==============================="
log_only "ALERT_EMAIL=${ALERT_EMAIL}"
[[ $FORCE_REINSTALL == true ]] && log_only "FORCE Mode: ENABLED"
[[ $REPAIR_MODE == true ]] && log_only "Repair Mode: ENABLED"
[[ $DRY_RUN == true ]] && log_only "Dry Run: ENABLED"
[[ $TIDY_MODE == true ]] && log_only "Tidy Mode: ENABLED"
echo "" >> "$LOG_FILE"

# Names that are hostile only at docroot or wp-content root (not deep in themes).
ROOT_BACKDOORS=("lock360.php" "wp-l0gin.php" "wp-theme.php" "wp-scripts.php" \
"mah.php" "jp.php" "ext.php" "is.php" "radio.php")

# Names that are hostile anywhere under the docroot except known-good trees.
ANYWHERE_BACKDOORS=("site-health-0ebcc2b0d37a.php" "rest-api-compat.php" \
"mail-transport.php" "sitemap-builder.php" "update-verify.php" \
"token-checker.php" "site-compat-layer.php" "wp-compat-layer.php" \
"sso-loader.php" "index-loop.php" "index-boolean.php" "index-num.php" \
"index-firewall.php" "index-beta.php" "update-checker-loop.php" \
"track-generator-call.php" "cafccefhgc.php" "site-speed-insights-d6e7.php" \
"smart-query-checker-bb8a.php")

KEEP_THEMES=("twentytwentyfive" "twentytwentyfour" "twentytwentythree" "twentytwentytwo")

file_looks_malicious() {
    local f="$1"
    grep -qE 'AVRIL_START|e6a8b4fc615171b4|@eval\s*\(\s*\$_SERVER|FilesMan|W2S::|gzinflate\s*\(\s*base64_decode' "$f" 2>/dev/null
}

is_known_good_dropin() {
    local f="$1" base
    base=$(basename "$f")
    case "$base" in
        db.php)
            grep -q 'Query Monitor Database Class' "$f" && return 0
            ;;
        advanced-cache.php|object-cache.php)
            grep -q 'W3 Total Cache' "$f" && return 0
            ;;
    esac
    return 1
}

is_allowed_mu() {
    local name="$1" a
    for a in "${ALLOWED_MU_PLUGINS[@]}"; do
        [[ "$name" == "$a" ]] && return 0
    done
    return 1
}

quarantine_file() {
    local src="$1" site="$2"
    local dest_dir dest
    dest_dir="${QUARANTINE_BASE}/$(date +%Y%m%d)/${site}"
    dest="${dest_dir}/$(date +%H%M%S)-$(basename "$src")"
    if $DRY_RUN; then
        log "[Dry Run] Would quarantine $src -> $dest"
        return 0
    fi
    mkdir -p "$dest_dir"
    if mv "$src" "$dest"; then
        chmod 600 "$dest" 2>/dev/null || true
        QUARANTINED=$((QUARANTINED + 1))
        alert "$site quarantined $src -> $dest"
        return 0
    fi
    log "[ERROR] Failed to quarantine $src"
    return 1
}

wp_at() {
    local path="$1"
    shift
    $WP_CLI --path="$path" "$@"
}

scan_and_quarantine_files() {
    local DOCROOT="$1" SITE_NAME="$2"
    local f

    for f in "${ROOT_BACKDOORS[@]}"; do
        [[ -f "$DOCROOT/$f" ]] && quarantine_file "$DOCROOT/$f" "$SITE_NAME"
        [[ -f "$DOCROOT/wp-content/$f" ]] && quarantine_file "$DOCROOT/wp-content/$f" "$SITE_NAME"
    done

    local name
    for name in "${ANYWHERE_BACKDOORS[@]}"; do
        while IFS= read -r f; do
            [[ -n "$f" ]] && quarantine_file "$f" "$SITE_NAME"
        done < <(find "$DOCROOT" -type f -name "$name" \
            ! -path '*/cache/*' ! -path '*/upgrade/*' 2>/dev/null)
    done

    # site-health-HASH.php planted in wp-content (not wp-admin)
    while IFS= read -r f; do
        [[ -n "$f" ]] && quarantine_file "$f" "$SITE_NAME"
    done < <(find "$DOCROOT/wp-content" -maxdepth 2 -type f -name 'site-health-*.php' 2>/dev/null)

    if [[ -f "$DOCROOT/wp-content/wp-login.php" ]]; then
        quarantine_file "$DOCROOT/wp-content/wp-login.php" "$SITE_NAME"
    fi

    if grep -qE '@eval\s*\(\s*\$_SERVER' "$DOCROOT/wp-config.php" 2>/dev/null; then
        if $DRY_RUN; then
            log "[Dry Run] Would strip eval from wp-config.php"
        else
            cp -a "$DOCROOT/wp-config.php" "${QUARANTINE_BASE}/$(date +%Y%m%d)/${SITE_NAME}/wp-config.php.bak" 2>/dev/null || true
            sed -i '/@eval\s*(\s*\$_SERVER/d' "$DOCROOT/wp-config.php"
            alert "$SITE_NAME stripped @eval(\$_SERVER...) from wp-config.php"
        fi
    fi

    local drop
    for drop in db.php advanced-cache.php object-cache.php; do
        f="$DOCROOT/wp-content/$drop"
        [[ -f "$f" ]] || continue
        if is_known_good_dropin "$f"; then
            continue
        fi
        quarantine_file "$f" "$SITE_NAME"
    done

    if [[ -d "$DOCROOT/wp-content/mu-plugins" ]]; then
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            if ! is_allowed_mu "$(basename "$f")"; then
                quarantine_file "$f" "$SITE_NAME"
            fi
        done < <(find "$DOCROOT/wp-content/mu-plugins" -maxdepth 1 -type f -name '*.php' 2>/dev/null)
    fi
}

quarantine_unowned_snippets() {
    local DOCROOT="$1" SITE_NAME="$2"
    local tables table cols blob ids id
    [[ -z "$SNIPPET_OWNER_MARK" ]] && return 0
    tables=$(wp_at "$DOCROOT" db query "SHOW TABLES LIKE '%snippet%'" --skip-column-names 2>/dev/null) || return 0
    [[ -z "$tables" ]] && return 0

    for table in $tables; do
        cols=$(wp_at "$DOCROOT" db query "SHOW COLUMNS FROM \`${table}\`" --skip-column-names 2>/dev/null) || continue
        echo "$cols" | grep -q '^code' || continue
        echo "$cols" | grep -q '^active' || continue
        echo "$cols" | grep -q '^name' || continue
        blob="IFNULL(name,''), IFNULL(code,'')"
        echo "$cols" | grep -q '^description' && blob="IFNULL(name,''), IFNULL(description,''), IFNULL(code,'')"
        ids=$(wp_at "$DOCROOT" db query "SELECT id FROM \`${table}\` WHERE active <> 0 AND CONCAT(${blob}) NOT LIKE '%${SNIPPET_OWNER_MARK}%'" --skip-column-names 2>/dev/null) || continue
        [[ -z "$ids" ]] && continue
        for id in $ids; do
            [[ -z "$id" ]] && continue
            if $DRY_RUN; then
                log "[Dry Run] Would quarantine unowned snippet ${table} id=${id}"
            else
                wp_at "$DOCROOT" db query "UPDATE \`${table}\` SET active=0, name=CONCAT('[UNAUTHORIZED] ', name) WHERE id=${id} AND name NOT LIKE '[UNAUTHORIZED]%'" >/dev/null
                alert "$SITE_NAME deactivated unowned snippet ${table} id=${id}"
            fi
        done
    done
}

flag_attacker_admins() {
    local DOCROOT="$1" SITE_NAME="$2"
    local rows
    rows=$(wp_at "$DOCROOT" db query "SELECT u.user_login FROM wp_users u JOIN wp_usermeta m ON u.ID=m.user_id WHERE m.meta_key LIKE '%capabilities' AND m.meta_value LIKE '%administrator%' AND (
        u.user_login REGEXP '^(w2s_|wp2_|wp2s_|wpsvc_|nx_|wordpress_|wp_admin_|admin_mg)'
        OR u.user_login IN ('backupadmin','itadmin','seomanager2026','whoadminknows','bennett','wpenginebot','wp-backup')
    )" --skip-column-names 2>/dev/null) || return 0
    [[ -z "$rows" ]] && return 0
    local login
    for login in $rows; do
        alert "$SITE_NAME attacker-pattern administrator still present: ${login}"
    done
}

flag_option_blobs() {
    local DOCROOT="$1" SITE_NAME="$2"
    local rows
    rows=$(wp_at "$DOCROOT" db query "SELECT option_name, LENGTH(option_value) FROM wp_options WHERE (option_name IN ('_wp_recovery_mode_data','_site_transient_health') OR option_name LIKE '_wp_core_settings_cache%') AND LENGTH(option_value) > 1000" --skip-column-names 2>/dev/null) || return 0
    [[ -z "$rows" ]] && return 0
    if $DRY_RUN; then
        log "[Dry Run] Would delete restorer option blobs on $SITE_NAME"
        return 0
    fi
    wp_at "$DOCROOT" db query "DELETE FROM wp_options WHERE option_name IN ('_wp_recovery_mode_data','_site_transient_health') OR option_name LIKE '_wp_core_settings_cache%'" >/dev/null
    alert "$SITE_NAME deleted restorer option blob(s)"
}

htaccess_looks_hostile() {
    local f="$1"
    grep -qE 'php_value[[:space:]]+auto_prepend|php_value[[:space:]]+auto_append|<FilesMatch.*\.php|eval\(|base64_decode' "$f" 2>/dev/null
}

scan_site() {
    local SITE_DIR="$1"
    local DOCROOT="$2"
    [[ ! -d "$SITE_DIR" ]] && return
    if $NO_SYMLINKS && [[ -L "$SITE_DIR" ]]; then
        log "[SKIP] $(basename "$SITE_DIR") is a symlink"
        return
    fi

    local SITE_NAME
    SITE_NAME=$(basename "$SITE_DIR")

    log "Checking $SITE_NAME..."

    local CORE_REINSTALLED=false
    local THEME_DELETED=0
    local PLUGIN_DELETED=0
    local THEME_REINSTALLED=0
    local PLUGIN_REINSTALLED=0
    local HTACCESS_RESET=false
    local extras_logged=0

    if [[ ! -d "$DOCROOT" ]]; then
        log "[SKIP] $SITE_NAME has no docroot at $DOCROOT"
        return
    fi
    if [[ ! -f "$DOCROOT/wp-config.php" ]]; then
        log "[SKIP] $SITE_NAME missing wp-config.php"
        return
    fi

    # Mitigate first so WP-CLI cannot load droppers as root.
    scan_and_quarantine_files "$DOCROOT" "$SITE_NAME"

    local OUTPUT=""
    if $FORCE_REINSTALL; then
        local VERSION
        VERSION=$(wp_at "$DOCROOT" core version 2>/dev/null)
        if [[ -n "$VERSION" ]]; then
            log "Forcing reinstall of WordPress $VERSION for $SITE_NAME"
            if $DRY_RUN; then
                log "[Dry Run] Would run: wp core download --version=$VERSION --force"
            else
                wp_at "$DOCROOT" core download --version="$VERSION" --force >> "$LOG_FILE" 2>&1
                CORE_REINSTALLED=true
            fi
        else
            log "[ERROR] Could not determine WP version for $SITE_NAME"
        fi
        OUTPUT=$(wp_at "$DOCROOT" core verify-checksums 2>&1)
    else
        OUTPUT=$(wp_at "$DOCROOT" core verify-checksums 2>&1)
        if echo "$OUTPUT" | grep -q "Success:"; then
            log "[OK] $SITE_NAME core files verified"
        else
            log "[FAIL] $SITE_NAME may be compromised"
            alert "$SITE_NAME core checksum failed"
        fi
        echo "$OUTPUT" | while IFS= read -r line; do log_only "$line"; done

        if $REPAIR_MODE && echo "$OUTPUT" | grep -q "doesn't verify against checksums"; then
            local VERSION
            VERSION=$(wp_at "$DOCROOT" core version 2>/dev/null)
            if [[ -n "$VERSION" ]]; then
                if $DRY_RUN; then
                    log "[Dry Run] Would reinstall core $VERSION"
                else
                    log "Re-downloading core files ($VERSION)..."
                    wp_at "$DOCROOT" core download --version="$VERSION" --force >> "$LOG_FILE" 2>&1
                    CORE_REINSTALLED=true
                fi
            fi
        fi
    fi

    # Extra files: quarantine only if they look malicious.
    local line file full
    while IFS= read -r line; do
        file=$(echo "$line" | sed -n 's/.*should not exist: \(.*\)$/\1/p' | xargs)
        [[ -z "$file" ]] && continue
        full="$DOCROOT/$file"
        [[ -f "$full" ]] || continue
        extras_logged=$((extras_logged + 1))
        if file_looks_malicious "$full"; then
            quarantine_file "$full" "$SITE_NAME"
        else
            log "Unexpected core extra (left in place): $file"
        fi
    done < <(echo "$OUTPUT" | grep -E "Warning: File should not exist:" || true)

    quarantine_unowned_snippets "$DOCROOT" "$SITE_NAME"
    flag_attacker_admins "$DOCROOT" "$SITE_NAME"
    flag_option_blobs "$DOCROOT" "$SITE_NAME"

    local HTACCESS="$DOCROOT/.htaccess"
    if $REPAIR_MODE || $FORCE_REINSTALL; then
        if [[ ! -f "$HTACCESS" ]]; then
            if $DRY_RUN; then
                log "[Dry Run] Would create standard .htaccess"
            else
                printf '%s\n' "# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\\.php\$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress" > "$HTACCESS"
                HTACCESS_RESET=true
            fi
        elif htaccess_looks_hostile "$HTACCESS"; then
            quarantine_file "$HTACCESS" "$SITE_NAME"
            HTACCESS_RESET=true
        fi
    fi

    if $TIDY_MODE; then
        local theme plugin keep
        if $DRY_RUN; then
            log "[Dry Run] Would tidy inactive themes/plugins"
        else
            mapfile -t _themes < <(wp_at "$DOCROOT" theme list --status=inactive --field=name 2>/dev/null)
            for theme in "${_themes[@]:-}"; do
                [[ -z "$theme" ]] && continue
                keep=false
                for k in "${KEEP_THEMES[@]}"; do
                    [[ "$theme" == "$k" ]] && keep=true
                done
                $keep && continue
                wp_at "$DOCROOT" theme delete "$theme" >> "$LOG_FILE" 2>&1 && THEME_DELETED=$((THEME_DELETED + 1))
            done
            mapfile -t _plugins < <(wp_at "$DOCROOT" plugin list --status=inactive --field=name 2>/dev/null)
            for plugin in "${_plugins[@]:-}"; do
                [[ -z "$plugin" ]] && continue
                wp_at "$DOCROOT" plugin delete "$plugin" >> "$LOG_FILE" 2>&1 && PLUGIN_DELETED=$((PLUGIN_DELETED + 1))
            done
        fi
    fi

    if $REPAIR_MODE; then
        local theme plugin
        if $DRY_RUN; then
            log "[Dry Run] Would reinstall active themes and plugins"
        else
            mapfile -t _athemes < <(wp_at "$DOCROOT" theme list --status=active --field=name 2>/dev/null)
            for theme in "${_athemes[@]:-}"; do
                [[ -z "$theme" ]] && continue
                wp_at "$DOCROOT" theme install "$theme" --force >> "$LOG_FILE" 2>&1 && THEME_REINSTALLED=$((THEME_REINSTALLED + 1))
            done
            mapfile -t _aplugins < <(wp_at "$DOCROOT" plugin list --status=active --field=name 2>/dev/null)
            for plugin in "${_aplugins[@]:-}"; do
                [[ -z "$plugin" ]] && continue
                wp_at "$DOCROOT" plugin install "$plugin" --force >> "$LOG_FILE" 2>&1 && PLUGIN_REINSTALLED=$((PLUGIN_REINSTALLED + 1))
            done
        fi
    fi

    local summary="Summary for $SITE_NAME: unexpected extras noted=${extras_logged}, htaccess reset: $( $HTACCESS_RESET && echo yes || echo no )"
    $TIDY_MODE && summary+=", themes deleted: $THEME_DELETED, plugins deleted: $PLUGIN_DELETED"
    $REPAIR_MODE && summary+=", themes reinstalled: $THEME_REINSTALLED, plugins reinstalled: $PLUGIN_REINSTALLED"
    log "$summary"
    echo "" >> "$LOG_FILE"
}

collect_sites() {
    if [[ -n "$SINGLE_DOCROOT" ]]; then
        printf '%s\t%s\n' "$(dirname "$SINGLE_DOCROOT")" "$SINGLE_DOCROOT"
        return
    fi
    if compgen -G "${BASE_DIR}/web*/${DOCROOT_NAME}/wp-config.php" > /dev/null; then
        local dir
        for dir in "$BASE_DIR"/web*; do
            [[ -d "$dir" ]] || continue
            if $NO_SYMLINKS && [[ -L "$dir" ]]; then
                continue
            fi
            printf '%s\t%s\n' "$dir" "$dir/$DOCROOT_NAME"
        done
        return
    fi
    local client dir
    for client in "$BASE_DIR"/client*; do
        [[ -d "$client" ]] || continue
        for dir in "$client"/web*; do
            [[ -d "$dir" ]] || continue
            if $NO_SYMLINKS && [[ -L "$dir" ]]; then
                continue
            fi
            printf '%s\t%s\n' "$dir" "$dir/$DOCROOT_NAME"
        done
    done
}

send_alert_mail() {
    $SEND_MAIL || return 0
    [[ -z "$ALERT_EMAIL" ]] && return 0
    if [[ ${#ALERTS[@]} -eq 0 ]]; then
        return 0
    fi
    local subject body
    subject="PantiMal: ${#ALERTS[@]} finding(s) on $(hostname)"
    body="PantiMal finished at $(timestamp) on $(hostname)
Log: ${LOG_FILE}
Quarantine: ${QUARANTINE_BASE}

Findings:
"
    local a
    for a in "${ALERTS[@]}"; do
        body+=" - ${a}"$'\n'
    done
    if command -v mail >/dev/null 2>&1; then
        printf '%s\n' "$body" | mail -s "$subject" "$ALERT_EMAIL" && log "Alert mail sent to ${ALERT_EMAIL}"
    elif command -v mailx >/dev/null 2>&1; then
        printf '%s\n' "$body" | mailx -s "$subject" "$ALERT_EMAIL" && log "Alert mail sent to ${ALERT_EMAIL}"
    else
        log "[ERROR] mail/mailx not found; could not send alert to ${ALERT_EMAIL}"
    fi
}

while IFS=$'\t' read -r site_dir docroot; do
    [[ -z "$site_dir" ]] && continue
    scan_site "$site_dir" "$docroot"
done < <(collect_sites)

log "All done. quarantined_ops=${QUARANTINED} alerts=${#ALERTS[@]}  See $LOG_FILE"
send_alert_mail
