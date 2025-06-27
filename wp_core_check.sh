#!/bin/bash

BASE_DIR="/var/www/clients/client1"
LOG_FILE=""
APPEND_MODE=false
REPAIR_MODE=false
DRY_RUN=false
FORCE_REINSTALL=false
WP_CLI="wp"

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

log() {
    echo "[$(timestamp)] $*" | tee -a "$LOG_FILE"
}

log_only() {
    echo "[$(timestamp)] $*" >> "$LOG_FILE"
}

# Parse flags
for arg in "$@"; do
    case $arg in
        --repair)
            REPAIR_MODE=true
            ;;
        --dry-run)
            DRY_RUN=true
            ;;
        --force)
            FORCE_REINSTALL=true
            ;;
        --append)
            APPEND_MODE=true
            ;;
        --log-file=*)
            LOG_FILE="${arg#*=}"
            ;;
        --wp-cli=*)
            WP_CLI="${arg#*=}"
            ;;
    esac
done

if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="/var/www/clients/client1/core-checksums-report.log"
fi



# Banner
if $APPEND_MODE; then
    log_only "Starting core integrity check..."
else
    echo "[$(timestamp)] Starting core integrity check..." > "$LOG_FILE"
fi
log_only "==============================="
[[ $FORCE_REINSTALL == true ]] && log_only "FORCE Mode: ENABLED (reinstalling WordPress core for ALL sites)"
[[ $REPAIR_MODE == true ]] && log_only "Repair Mode: ENABLED"
[[ $DRY_RUN == true ]] && log_only "Dry Run: ENABLED (no changes will be made)"
echo "" >> "$LOG_FILE"

# Suspicious file list (excludes legit WP core files)
SUSPICIOUS_FILES=("about.php" "radio.php" "content.php" "lock360.php" "admin.php" \
"wp-l0gin.php" "wp-theme.php" "wp-scripts.php" "wp-editor.php" "mah.php" "jp.php" "ext.php")

# Standard WP .htaccess
STANDARD_HTACCESS_CONTENT=$(cat <<'EOF'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
EOF
)

# Main loop
for dir in "$BASE_DIR"/web[0-9]*; do
    SITE_NAME=$(basename "$dir")
    DOCROOT="$dir/web"

    log "Checking $SITE_NAME..."

    REMOVED_COUNT=0
    BACKDOOR_COUNT=0
    HTACCESS_DELETED=0
    HTACCESS_RESET=false

    if [ -d "$DOCROOT" ]; then
        cd "$DOCROOT" || continue

        # If FORCE is set, skip checking and just reinstall core
        if $FORCE_REINSTALL; then
            VERSION=$($WP_CLI core version --allow-root 2>/dev/null)
            if [[ -n "$VERSION" ]]; then
                log "Forcing reinstall of WordPress $VERSION for $SITE_NAME"
                if $DRY_RUN; then
                    log "[Dry Run] Would run: $WP_CLI core download --version=$VERSION --force --allow-root"
                else
                    $WP_CLI core download --version="$VERSION" --force --allow-root >> "$LOG_FILE" 2>&1
                fi
            else
                log "[ERROR] Could not determine WP version for $SITE_NAME"
            fi
        else
            OUTPUT=$($WP_CLI core verify-checksums --allow-root 2>&1)

            if echo "$OUTPUT" | grep -q "Success:"; then
                log "$(echo -e "\e[32m[OK]\e[0m $SITE_NAME core files verified")"
            else
                log "$(echo -e "\e[31m[FAIL]\e[0m $SITE_NAME may be compromised")"
            fi

            echo "$OUTPUT" | while IFS= read -r line; do log "$line"; done

            if $REPAIR_MODE && echo "$OUTPUT" | grep -q "doesn't verify against checksums"; then
                VERSION=$($WP_CLI core version --allow-root 2>/dev/null)
                if [[ -n "$VERSION" ]]; then
                    log "Detected version: $VERSION"
                    if $DRY_RUN; then
                        log "[Dry Run] Would run: $WP_CLI core download --version=$VERSION --force --allow-root"
                    else
                        log "Re-downloading core files..."
                        $WP_CLI core download --version="$VERSION" --force --allow-root >> "$LOG_FILE" 2>&1
                    fi
                else
                    log "Unable to determine WP version for $SITE_NAME"
                fi
            fi
        fi

        # If force was used, re-run checksum to find warnings
        if $FORCE_REINSTALL; then
            log "Re-checking for unexpected files after forced reinstall..."
            OUTPUT=$($WP_CLI core verify-checksums --allow-root 2>&1)
        fi

        # Parse & delete rogue files from "should not exist" warnings
        echo "$OUTPUT" | grep -E "Warning: File should not exist:" | while read -r line; do
            FILE=$(echo "$line" | sed -n 's/.*should not exist: \(.*\)$/\1/p' | xargs)
            FULL_PATH="$DOCROOT/$FILE"
            if [[ -f "$FULL_PATH" ]]; then
                if $DRY_RUN; then
                    log "[Dry Run] Would delete: $FULL_PATH"
                else
                    log "Removing unexpected file: $FULL_PATH"
                    rm -f "$FULL_PATH"
                    ((REMOVED_COUNT++))
                fi
            fi
        done

        # Delete known malicious backdoor filenames
        for F in "${SUSPICIOUS_FILES[@]}"; do
            FILE_PATH="$DOCROOT/$F"
            if [[ -f "$FILE_PATH" ]]; then
                if $DRY_RUN; then
                    log "[Dry Run] Would delete backdoor file: $FILE_PATH"
                else
                    log "Deleting backdoor file: $FILE_PATH"
                    rm -f "$FILE_PATH"
                    ((BACKDOOR_COUNT++))
                fi
            fi
        done

        # Reset .htaccess to standard WordPress
        HTACCESS="$DOCROOT/.htaccess"
        if $REPAIR_MODE || $FORCE_REINSTALL; then
            if [[ -f "$HTACCESS" ]]; then
                if $DRY_RUN; then
                    log "[Dry Run] Would replace .htaccess in $SITE_NAME with standard WP config"
                else
                    log "Backing up and resetting .htaccess in $SITE_NAME"
                    cp "$HTACCESS" "$HTACCESS.bak"
                    echo "$STANDARD_HTACCESS_CONTENT" > "$HTACCESS"
                    HTACCESS_RESET=true
                fi
            else
                if $DRY_RUN; then
                    log "[Dry Run] Would create new .htaccess in $SITE_NAME"
                else
                    log "Creating new standard .htaccess in $SITE_NAME"
                    echo "$STANDARD_HTACCESS_CONTENT" > "$HTACCESS"
                    HTACCESS_RESET=true
                fi
            fi
        fi

	# Remove .htaccess files under wp-content/, excluding uploads/ and cache/
	WPCONTENT="$DOCROOT/wp-content"
        if [ -d "$WPCONTENT" ]; then
            log "Scanning for rogue .htaccess files in $WPCONTENT (excluding uploads/ and cache/)"
            find "$WPCONTENT" \( -path "$WPCONTENT/uploads" -o -path "$WPCONTENT/cache" \) -prune -o -type f -name ".htaccess" -print | while read -r HTFILE; do
                if $DRY_RUN; then
                    log "[Dry Run] Would delete: $HTFILE"
                else
                    log "Deleting rogue .htaccess: $HTFILE"
                    rm -f "$HTFILE"
                    ((HTACCESS_DELETED++))
                fi
            done
        fi



        log "Summary for $SITE_NAME: removed $REMOVED_COUNT unexpected file(s), deleted $BACKDOOR_COUNT backdoor file(s), deleted $HTACCESS_DELETED rogue .htaccess file(s), htaccess reset: $( $HTACCESS_RESET && echo yes || echo no )"
        echo "" >> "$LOG_FILE"
    else
        log "[SKIP] $SITE_NAME has no docroot at $DOCROOT"
    fi
done

log "All done. See $LOG_FILE for full results."
