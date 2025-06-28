#!/bin/bash

BASE_DIR="/var/www/clients/client1"
DOCROOT_NAME="web"
NO_SYMLINKS=false
LOG_FILE=""
APPEND_MODE=false
REPAIR_MODE=false
DRY_RUN=false
FORCE_REINSTALL=false
TIDY_MODE=false
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
        --base-dir=*)
            BASE_DIR="${arg#*=}"
            ;;
        --docroot=*)
            DOCROOT_NAME="${arg#*=}"
            ;;
        --no-symlinks)
            NO_SYMLINKS=true
            ;;
        --tidy)
            TIDY_MODE=true
            ;;
    esac
done

# Ensure WP-CLI does not load plugins or themes to avoid errors
WP_CLI="$WP_CLI --skip-plugins --skip-themes"

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
[[ $TIDY_MODE == true ]] && log_only "Tidy Mode: ENABLED (removing inactive themes/plugins)"
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
for dir in "$BASE_DIR"/*; do
    [[ ! -d "$dir" ]] && continue
    if $NO_SYMLINKS && [[ -L "$dir" ]]; then
        log "[SKIP] $(basename "$dir") is a symlink"
        continue
    fi

    SITE_NAME=$(basename "$dir")
    DOCROOT="$dir/$DOCROOT_NAME"

    log "Checking $SITE_NAME..."

    REMOVED_COUNT=0
    BACKDOOR_COUNT=0
    HTACCESS_DELETED=0
    HTACCESS_RESET=false
    THEME_DELETED=0
    PLUGIN_DELETED=0
    THEME_REINSTALLED=0
    PLUGIN_REINSTALLED=0
    CORE_REINSTALLED=false

    if [ -d "$DOCROOT" ]; then
        if [[ ! -f "$DOCROOT/wp-config.php" ]]; then
            log "[SKIP] $SITE_NAME missing wp-config.php in $DOCROOT"
            continue
        fi
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
                    CORE_REINSTALLED=true
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
                        CORE_REINSTALLED=true
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
        if $TIDY_MODE; then
            log "Inactive Themes:"
            $WP_CLI theme list --status=inactive --allow-root | while IFS= read -r line; do log "$line"; done

            log "Inactive Plugins:"
            $WP_CLI plugin list --status=inactive --allow-root | while IFS= read -r line; do log "$line"; done

            if $DRY_RUN; then
                log "[Dry Run] Would delete inactive themes and plugins"
            else
                log "Deleting inactive themes..."
                for theme in $($WP_CLI theme list --status=inactive --field=name --allow-root); do
                    $WP_CLI theme delete "$theme" --allow-root >> "$LOG_FILE" 2>&1
                    ((THEME_DELETED++))
                done

                log "Deleting inactive plugins..."
                for plugin in $($WP_CLI plugin list --status=inactive --field=name --allow-root); do
                    $WP_CLI plugin delete "$plugin" --allow-root >> "$LOG_FILE" 2>&1
                    ((PLUGIN_DELETED++))
                done
            fi
        fi

        if $REPAIR_MODE && $CORE_REINSTALLED; then
            if $DRY_RUN; then
                log "[Dry Run] Would reinstall active themes and plugins"
                for theme in $($WP_CLI theme list --status=active --field=name --allow-root); do
                    log "[Dry Run] Would run: $WP_CLI theme install $theme --force --allow-root"
                done
                for plugin in $($WP_CLI plugin list --status=active --field=name --allow-root); do
                    log "[Dry Run] Would run: $WP_CLI plugin install $plugin --force --allow-root"
                done
            else
                log "Reinstalling active themes..."
                for theme in $($WP_CLI theme list --status=active --field=name --allow-root); do
                    $WP_CLI theme install "$theme" --force --allow-root >> "$LOG_FILE" 2>&1
                    ((THEME_REINSTALLED++))
                done
                log "Reinstalling active plugins..."
                for plugin in $($WP_CLI plugin list --status=active --field=name --allow-root); do
                    $WP_CLI plugin install "$plugin" --force --allow-root >> "$LOG_FILE" 2>&1
                    ((PLUGIN_REINSTALLED++))
                done
            fi
        fi



        SUMMARY="Summary for $SITE_NAME: removed $REMOVED_COUNT unexpected file(s), deleted $BACKDOOR_COUNT backdoor file(s), deleted $HTACCESS_DELETED rogue .htaccess file(s), htaccess reset: $( $HTACCESS_RESET && echo yes || echo no )"
        if $TIDY_MODE; then
            SUMMARY+=", themes deleted: $THEME_DELETED, plugins deleted: $PLUGIN_DELETED"
        fi
        if $REPAIR_MODE && $CORE_REINSTALLED; then
            SUMMARY+=", themes reinstalled: $THEME_REINSTALLED, plugins reinstalled: $PLUGIN_REINSTALLED"
        fi
        log "$SUMMARY"
        echo "" >> "$LOG_FILE"
    else
        log "[SKIP] $SITE_NAME has no docroot at $DOCROOT"
    fi
done

log "All done. See $LOG_FILE for full results."
