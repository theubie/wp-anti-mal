#!/bin/bash

BASE_DIR="/var/www/clients/client1"
LOG_FILE=""
APPEND_MODE=false
REPAIR_MODE=false
DRY_RUN=false
FORCE_REINSTALL=false

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
    esac
done

if [[ -z "$LOG_FILE" ]]; then
    LOG_FILE="/var/www/clients/client1/core-checksums-report.log"
fi



# Banner
if $APPEND_MODE; then
    echo "Starting core integrity check..." >> "$LOG_FILE"
else
    echo "Starting core integrity check..." > "$LOG_FILE"
fi
echo "===============================" >> "$LOG_FILE"
[[ $FORCE_REINSTALL == true ]] && echo "FORCE Mode: ENABLED (reinstalling WordPress core for ALL sites)" >> "$LOG_FILE"
[[ $REPAIR_MODE == true ]] && echo "Repair Mode: ENABLED" >> "$LOG_FILE"
[[ $DRY_RUN == true ]] && echo "Dry Run: ENABLED (no changes will be made)" >> "$LOG_FILE"
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

    echo "Checking $SITE_NAME..." | tee -a "$LOG_FILE"

    if [ -d "$DOCROOT" ]; then
        cd "$DOCROOT" || continue

        # If FORCE is set, skip checking and just reinstall core
        if $FORCE_REINSTALL; then
            VERSION=$(wp core version --allow-root 2>/dev/null)
            if [[ -n "$VERSION" ]]; then
                echo "Forcing reinstall of WordPress $VERSION for $SITE_NAME" | tee -a "$LOG_FILE"
                if $DRY_RUN; then
                    echo "[Dry Run] Would run: wp core download --version=$VERSION --force --allow-root" | tee -a "$LOG_FILE"
                else
                    wp core download --version="$VERSION" --force --allow-root >> "$LOG_FILE" 2>&1
                fi
            else
                echo "[ERROR] Could not determine WP version for $SITE_NAME" | tee -a "$LOG_FILE"
            fi
        else
            OUTPUT=$(wp core verify-checksums --allow-root 2>&1)

            if echo "$OUTPUT" | grep -q "Success:"; then
                echo -e "\e[32m[OK]\e[0m $SITE_NAME core files verified" | tee -a "$LOG_FILE"
            else
                echo -e "\e[31m[FAIL]\e[0m $SITE_NAME may be compromised" | tee -a "$LOG_FILE"
            fi

            echo "$OUTPUT" | tee -a "$LOG_FILE"

            if $REPAIR_MODE && echo "$OUTPUT" | grep -q "doesn't verify against checksums"; then
                VERSION=$(wp core version --allow-root 2>/dev/null)
                if [[ -n "$VERSION" ]]; then
                    echo "Detected version: $VERSION" | tee -a "$LOG_FILE"
                    if $DRY_RUN; then
                        echo "[Dry Run] Would run: wp core download --version=$VERSION --force --allow-root" | tee -a "$LOG_FILE"
                    else
                        echo "Re-downloading core files..." | tee -a "$LOG_FILE"
                        wp core download --version="$VERSION" --force --allow-root >> "$LOG_FILE" 2>&1
                    fi
                else
                    echo "Unable to determine WP version for $SITE_NAME" | tee -a "$LOG_FILE"
                fi
            fi
        fi

        # If force was used, re-run checksum to find warnings
        if $FORCE_REINSTALL; then
            echo "Re-checking for unexpected files after forced reinstall..." | tee -a "$LOG_FILE"
            OUTPUT=$(wp core verify-checksums --allow-root 2>&1)
        fi

        # Parse & delete rogue files from "should not exist" warnings
        echo "$OUTPUT" | grep -E "Warning: File should not exist:" | while read -r line; do
            FILE=$(echo "$line" | sed -n 's/.*should not exist: \(.*\)$/\1/p' | xargs)
            FULL_PATH="$DOCROOT/$FILE"
            if [[ -f "$FULL_PATH" ]]; then
                if $DRY_RUN; then
                    echo "[Dry Run] Would delete: $FULL_PATH" | tee -a "$LOG_FILE"
                else
                    echo "Removing unexpected file: $FULL_PATH" | tee -a "$LOG_FILE"
                    rm -f "$FULL_PATH"
                fi
            fi
        done

        # Delete known malicious backdoor filenames
        for F in "${SUSPICIOUS_FILES[@]}"; do
            FILE_PATH="$DOCROOT/$F"
            if [[ -f "$FILE_PATH" ]]; then
                if $DRY_RUN; then
                    echo "[Dry Run] Would delete backdoor file: $FILE_PATH" | tee -a "$LOG_FILE"
                else
                    echo "Deleting backdoor file: $FILE_PATH" | tee -a "$LOG_FILE"
                    rm -f "$FILE_PATH"
                fi
            fi
        done

        # Reset .htaccess to standard WordPress
        HTACCESS="$DOCROOT/.htaccess"
        if $REPAIR_MODE || $FORCE_REINSTALL; then
            if [[ -f "$HTACCESS" ]]; then
                if $DRY_RUN; then
                    echo "[Dry Run] Would replace .htaccess in $SITE_NAME with standard WP config" | tee -a "$LOG_FILE"
                else
                    echo "Backing up and resetting .htaccess in $SITE_NAME" | tee -a "$LOG_FILE"
                    cp "$HTACCESS" "$HTACCESS.bak"
                    echo "$STANDARD_HTACCESS_CONTENT" > "$HTACCESS"
                fi
            else
                if $DRY_RUN; then
                    echo "[Dry Run] Would create new .htaccess in $SITE_NAME" | tee -a "$LOG_FILE"
                else
                    echo "Creating new standard .htaccess in $SITE_NAME" | tee -a "$LOG_FILE"
                    echo "$STANDARD_HTACCESS_CONTENT" > "$HTACCESS"
                fi
            fi
        fi

	# Remove .htaccess files under wp-content/, excluding uploads/ and cache/
	WPCONTENT="$DOCROOT/wp-content"
	if [ -d "$WPCONTENT" ]; then
	    echo "Scanning for rogue .htaccess files in $WPCONTENT (excluding uploads/ and cache/)" | tee -a "$LOG_FILE"
	    find "$WPCONTENT" \( -path "$WPCONTENT/uploads" -o -path "$WPCONTENT/cache" \) -prune -o \
	        -type f -name ".htaccess" -print | while read -r HTFILE; do
	        if $DRY_RUN; then
	            echo "[Dry Run] Would delete: $HTFILE" | tee -a "$LOG_FILE"
	        else
	            echo "Deleting rogue .htaccess: $HTFILE" | tee -a "$LOG_FILE"
	            rm -f "$HTFILE"
	        fi
	    done
	fi



        echo "" >> "$LOG_FILE"
    else
        echo "[SKIP] $SITE_NAME has no docroot at $DOCROOT" | tee -a "$LOG_FILE"
    fi
done

echo "All done. See $LOG_FILE for full results."
