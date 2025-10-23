#!/bin/bash

# Fix Nextcloud SELinux contexts on SUSE Tumbleweed
# This script detects critical directories and applies proper SELinux contexts

set -e

# ============================================================================
# CONFIGURATION VARIABLES - Modify these if needed
# ============================================================================

# Nextcloud installation directory (webroot)
NEXTCLOUD_ROOT="/web/nextcloud"

# Override data directory (leave empty to auto-detect from config.php)
OVERRIDE_DATA_DIR=""

# Override PHP session directory (leave empty to auto-detect)
OVERRIDE_SESSION_DIR=""

# Path to Nextcloud config.php (relative to NEXTCLOUD_ROOT)
CONFIG_PATH="config/config.php"

# ============================================================================

echo "=== Nextcloud SELinux Configuration Script ==="
echo
echo "Nextcloud root: $NEXTCLOUD_ROOT"
echo

# Function to extract value from Nextcloud config.php
extract_from_config() {
    local key="$1"
    local config_file="$NEXTCLOUD_ROOT/$CONFIG_PATH"
    
    if [[ ! -f "$config_file" ]]; then
        echo "WARNING: Config file not found at $config_file" >&2
        return 1
    fi
    
    # Extract value from PHP array
    # This handles both single and double quotes
    local value=$(grep -E "^[[:space:]]*['\"]${key}['\"]" "$config_file" 2>/dev/null | \
                  sed -E "s/.*['\"]${key}['\"][[:space:]]*=>[[:space:]]*['\"]([^'\"]+)['\"].*/\1/" | \
                  tail -1)
    
    if [[ -n "$value" ]]; then
        echo "$value"
        return 0
    fi
    
    return 1
}

# Function to find data directory
find_data_directory() {
    if [[ -n "$OVERRIDE_DATA_DIR" ]]; then
        DATA_DIR="$OVERRIDE_DATA_DIR"
        echo "Using override data directory: $DATA_DIR"
        return 0
    fi
    
    echo "Detecting data directory from config.php..."
    
    if DATA_DIR=$(extract_from_config "datadirectory"); then
        echo "Found data directory in config: $DATA_DIR"
        
        if [[ ! -d "$DATA_DIR" ]]; then
            echo "WARNING: Data directory $DATA_DIR does not exist!"
            return 1
        fi
        
        return 0
    else
        # Fallback to default
        DATA_DIR="$NEXTCLOUD_ROOT/data"
        echo "Could not find datadirectory in config, using default: $DATA_DIR"
        
        if [[ ! -d "$DATA_DIR" ]]; then
            echo "ERROR: Data directory $DATA_DIR does not exist!"
            echo "Please set OVERRIDE_DATA_DIR at the top of this script."
            return 1
        fi
        
        return 0
    fi
}

# Function to find PHP session directory from config
find_php_session_dir() {
    if [[ -n "$OVERRIDE_SESSION_DIR" ]]; then
        PHP_SESSION_DIR="$OVERRIDE_SESSION_DIR"
        echo "Using override session directory: $PHP_SESSION_DIR"
        return 0
    fi
    
    local session_dir=""
    local php_configs=()
    
    echo "Searching for PHP session directory..."
    
    # Find all php.ini files
    php_configs+=($(find /etc -name "php.ini" 2>/dev/null || true))
    
    # Also check for PHP-FPM specific configs
    php_configs+=($(find /etc -path "*/fpm/php.ini" 2>/dev/null || true))
    php_configs+=($(find /etc -name "www.conf" -path "*/php*/fpm/*" 2>/dev/null || true))
    
    # Check each config for session.save_path
    for config in "${php_configs[@]}"; do
        if [[ -f "$config" ]]; then
            echo "Checking: $config"
            
            # Extract session.save_path from php.ini
            if [[ "$config" == *"php.ini" ]]; then
                session_dir=$(grep -E "^[[:space:]]*session\.save_path[[:space:]]*=" "$config" 2>/dev/null | sed 's/.*=[[:space:]]*"\?\([^"]*\)"\?.*/\1/' | tail -1)
            fi
            
            # Extract from PHP-FPM pool config
            if [[ "$config" == *"www.conf" ]]; then
                local fpm_session=$(grep -E "^[[:space:]]*php_value\[session\.save_path\]" "$config" 2>/dev/null | sed 's/.*=[[:space:]]*\(.*\)/\1/' | tail -1)
                if [[ -n "$fpm_session" ]]; then
                    session_dir="$fpm_session"
                fi
            fi
            
            if [[ -n "$session_dir" && -d "$session_dir" ]]; then
                echo "Found session directory in config: $session_dir"
                PHP_SESSION_DIR="$session_dir"
                return 0
            fi
        fi
    done
    
    # If not found in configs, check common locations
    local common_paths=(
        "/var/lib/php/sessions"
        "/var/lib/php/session"
        "/var/lib/php8/sessions"
        "/var/lib/php8/session"
        "/var/lib/php7/sessions"
        "/var/lib/php7/session"
        "/tmp"
        "/var/tmp"
    )
    
    for path in "${common_paths[@]}"; do
        if [[ -d "$path" ]]; then
            # Check if PHP is actually using this directory
            if ls "$path"/sess_* 2>/dev/null | head -1 >/dev/null; then
                echo "Found PHP session files in: $path"
                PHP_SESSION_DIR="$path"
                return 0
            fi
        fi
    done
    
    # Last resort: ask PHP directly
    if command -v php >/dev/null 2>&1; then
        session_dir=$(php -r 'echo ini_get("session.save_path");' 2>/dev/null || true)
        if [[ -n "$session_dir" && -d "$session_dir" ]]; then
            echo "Found session directory from PHP CLI: $session_dir"
            PHP_SESSION_DIR="$session_dir"
            return 0
        fi
    fi
    
    return 1
}

# Check if Nextcloud root exists
if [[ ! -d "$NEXTCLOUD_ROOT" ]]; then
    echo "ERROR: Nextcloud root directory $NEXTCLOUD_ROOT does not exist!"
    echo "Please set NEXTCLOUD_ROOT at the top of this script."
    exit 1
fi

# Find data directory
if ! find_data_directory; then
    echo "ERROR: Could not determine data directory!"
    echo "Please set OVERRIDE_DATA_DIR at the top of this script."
    exit 1
fi

# Detect PHP session directory
if ! find_php_session_dir; then
    echo
    echo "WARNING: Could not automatically detect PHP session directory."
    echo "Please enter the PHP session directory path manually."
    echo "You can find this in your php.ini or PHP-FPM pool config as 'session.save_path'"
    read -p "PHP session directory path: " PHP_SESSION_DIR
    
    if [[ ! -d "$PHP_SESSION_DIR" ]]; then
        echo "ERROR: Directory $PHP_SESSION_DIR does not exist!"
        exit 1
    fi
fi

echo
echo "=== Configuration Summary ==="
echo "Nextcloud root: $NEXTCLOUD_ROOT"
echo "Data directory: $DATA_DIR"
echo "PHP session directory: $PHP_SESSION_DIR"
echo

# Get parent directory of Nextcloud for base context
NEXTCLOUD_PARENT=$(dirname "$NEXTCLOUD_ROOT")

echo "=== Step 1: Setting base directory context ==="
semanage fcontext -a -t httpd_sys_content_t "${NEXTCLOUD_PARENT}(/.*)?" 2>/dev/null || echo "Context already exists for ${NEXTCLOUD_PARENT}"
restorecon -Rv "${NEXTCLOUD_PARENT}/"

echo
echo "=== Step 2: Removing existing Nextcloud contexts (if any) ==="
# Remove existing rules to avoid conflicts
semanage fcontext -d "${NEXTCLOUD_ROOT}/data(/.*)?" 2>/dev/null || true
semanage fcontext -d "${NEXTCLOUD_ROOT}/config(/.*)?" 2>/dev/null || true
semanage fcontext -d "${NEXTCLOUD_ROOT}/apps(/.*)?" 2>/dev/null || true
semanage fcontext -d "${NEXTCLOUD_ROOT}/.htaccess" 2>/dev/null || true
semanage fcontext -d "${NEXTCLOUD_ROOT}/.user.ini" 2>/dev/null || true
semanage fcontext -d "${NEXTCLOUD_ROOT}/3rdparty/aws/aws-sdk-php/src/data/logs(/.*)?" 2>/dev/null || true

# Also remove data directory context if it's outside webroot
if [[ "$DATA_DIR" != "${NEXTCLOUD_ROOT}/data" ]]; then
    semanage fcontext -d "${DATA_DIR}(/.*)?" 2>/dev/null || true
fi

echo
echo "=== Step 3: Adding correct Nextcloud contexts ==="
# Base Nextcloud directory - readable
semanage fcontext -a -t httpd_sys_content_t "${NEXTCLOUD_ROOT}(/.*)?"

# Writable directories within Nextcloud
semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_ROOT}/config(/.*)?"
semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_ROOT}/apps(/.*)?"
semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_ROOT}/.htaccess"
semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_ROOT}/.user.ini"
semanage fcontext -a -t httpd_sys_rw_content_t "${NEXTCLOUD_ROOT}/3rdparty/aws/aws-sdk-php/src/data/logs(/.*)?"

# Data directory (might be outside webroot)
if [[ "$DATA_DIR" == "${NEXTCLOUD_ROOT}/data" ]]; then
    # Data directory is inside Nextcloud root
    semanage fcontext -a -t httpd_sys_rw_content_t "${DATA_DIR}(/.*)?"
else
    # Data directory is outside Nextcloud root
    echo "Data directory is outside Nextcloud root, setting context separately..."
    semanage fcontext -a -t httpd_sys_rw_content_t "${DATA_DIR}(/.*)?"
fi

echo
echo "=== Step 4: Applying contexts ==="
restorecon -Rv "${NEXTCLOUD_ROOT}/"

# Apply context to data directory if it's outside webroot
if [[ "$DATA_DIR" != "${NEXTCLOUD_ROOT}/data" ]]; then
    restorecon -Rv "${DATA_DIR}/"
fi

echo
echo "=== Step 5: Fixing PHP session directory: $PHP_SESSION_DIR ==="
semanage fcontext -a -t httpd_sys_rw_content_t "${PHP_SESSION_DIR}(/.*)?" 2>/dev/null || echo "Context already exists"
restorecon -Rv "${PHP_SESSION_DIR}"

echo
echo "=== Step 6: Setting SELinux booleans ==="
echo "Enabling httpd_unified..."
setsebool -P httpd_unified on

echo "Enabling httpd_can_network_connect..."
setsebool -P httpd_can_network_connect on

echo "Enabling httpd_can_network_memcache..."
setsebool -P httpd_can_network_memcache on

echo "Enabling httpd_execmem for PHP-FPM..."
setsebool -P httpd_execmem on

# Check if data directory is on NFS
if df -T "$DATA_DIR" 2>/dev/null | grep -q nfs; then
    echo "Data directory appears to be on NFS, enabling NFS access..."
    echo "Enabling httpd_use_nfs..."
    setsebool -P httpd_use_nfs on
    
    echo "Enabling httpd_anon_write for NFS write access..."
    setsebool -P httpd_anon_write on
fi

echo
echo "=== Step 7: Verifying contexts ==="
echo "Nextcloud root:"
ls -dZ "${NEXTCLOUD_ROOT}/" | grep -E '(httpd_sys_content_t|httpd_sys_rw_content_t)' || echo "WARNING: Incorrect context!"

echo
echo "Nextcloud config:"
ls -dZ "${NEXTCLOUD_ROOT}/config/" | grep httpd_sys_rw_content_t || echo "WARNING: Incorrect context!"

echo
echo "Data directory:"
ls -dZ "${DATA_DIR}/" | grep -E '(httpd_sys_rw_content_t|nfs_t)' || echo "WARNING: Incorrect context!"

echo
echo "PHP session directory:"
ls -dZ "$PHP_SESSION_DIR" | grep httpd_sys_rw_content_t || echo "WARNING: Incorrect context!"

echo
echo "=== Step 8: Restarting services ==="
systemctl restart nginx
systemctl restart php-fpm

echo
echo "=== Configuration complete! ==="
echo
echo "To check for any remaining SELinux denials, run:"
echo "  ausearch -m avc,user_avc,selinux_err,user_selinux_err -ts recent"
echo
echo "If you still see denials, you may need to create a custom policy module."
echo
echo "Configuration used:"
echo "  Nextcloud root: $NEXTCLOUD_ROOT"
echo "  Data directory: $DATA_DIR"
echo "  PHP session: $PHP_SESSION_DIR"
