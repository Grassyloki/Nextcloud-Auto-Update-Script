#!/bin/bash

# Configuration variables
INSTALL_DIR="/web"              # Base installation directory (no trailing slash)
NEXTCLOUD_DIR="nextcloud"       # Nextcloud subdirectory name
WEB_SERVER="nginx"              # Web server service name
PHP_SERVICE="php-fpm.service"   # PHP-FPM service name
DATABASE_SERVICE="mariadb"      # Database service name
SELINUX_ENABLED=true            # Set to false to skip SELinux rule application
                                # When true, runs selinux.sh from the same directory as this script
                                # to apply SELinux contexts to the Nextcloud files

# Function to echo in cyan
echo_cyan() {
    echo -e "\033[0;36m$1\033[0m"
}

# Function to echo in yellow
echo_yellow() {
    echo -e "\033[0;33m$1\033[0m"
}

# Function to echo in green
echo_green() {
    echo -e "\033[0;32m$1\033[0m"
}

# Function to echo in red
echo_red() {
    echo -e "\033[0;31m$1\033[0m"
}

# Function to extract version components
parse_version() {
    local version_string=$1
    # Extract version numbers using regex
    if [[ $version_string =~ ([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
    else
        echo "0 0 0"
    fi
}

# Function to compare versions
# Returns 1 if version1 > version2, 0 otherwise
version_greater() {
    local v1_major=$1
    local v1_minor=$2
    local v1_bugfix=$3
    local v2_major=$4
    local v2_minor=$5
    local v2_bugfix=$6
    
    if [ "$v1_major" -gt "$v2_major" ]; then
        return 0
    elif [ "$v1_major" -eq "$v2_major" ] && [ "$v1_minor" -gt "$v2_minor" ]; then
        return 0
    elif [ "$v1_major" -eq "$v2_major" ] && [ "$v1_minor" -eq "$v2_minor" ] && [ "$v1_bugfix" -gt "$v2_bugfix" ]; then
        return 0
    fi
    return 1
}

# Function to check for active downloads
check_active_downloads() {
    local active_downloads=0
    
    echo_cyan "Checking for active downloads..."
    
    # Check nginx connections for download activity
    if command -v ss &> /dev/null; then
        # Look for established connections to port 80/443 with data transfer
        local active_connections=$(ss -tn state established '( sport = :80 or sport = :443 )' | grep -v LISTEN | wc -l)
        if [ "$active_connections" -gt 1 ]; then
            echo_yellow "Found $active_connections active HTTP/HTTPS connections"
            
            # Check for large data transfers (downloads typically have larger send queues)
            local large_transfers=$(ss -tn state established '( sport = :80 or sport = :443 )' | awk '$3 > 10000 {print}' | wc -l)
            if [ "$large_transfers" -gt 0 ]; then
                echo_yellow "Detected $large_transfers connections with significant data transfer"
                active_downloads=$((active_downloads + large_transfers))
            fi
        fi
    fi
    
    # Check PHP-FPM processes for file operations
    local php_processes=$(ps aux | grep -E 'php-fpm.*pool' | grep -v grep | wc -l)
    local busy_php_processes=$(ps aux | grep -E 'php-fpm.*pool' | grep -v grep | awk '$3 > 10.0' | wc -l)
    
    if [ "$busy_php_processes" -gt 0 ]; then
        echo_yellow "Found $busy_php_processes busy PHP processes (possibly handling downloads)"
        active_downloads=$((active_downloads + busy_php_processes))
    fi
    
    # Check Nextcloud database for active file operations (if we have access)
    if command -v mysql &> /dev/null && [ -f ${INSTALL_DIR}/${NEXTCLOUD_DIR}/config/config.php ]; then
        # Try to extract database credentials from config
        local db_name=$(grep "'dbname'" ${INSTALL_DIR}/${NEXTCLOUD_DIR}/config/config.php | sed "s/.*'dbname' => '\([^']*\)'.*/\1/")
        local db_user=$(grep "'dbuser'" ${INSTALL_DIR}/${NEXTCLOUD_DIR}/config/config.php | sed "s/.*'dbuser' => '\([^']*\)'.*/\1/")
        local db_pass=$(grep "'dbpassword'" ${INSTALL_DIR}/${NEXTCLOUD_DIR}/config/config.php | sed "s/.*'dbpassword' => '\([^']*\)'.*/\1/")
        
        if [ -n "$db_name" ] && [ -n "$db_user" ] && [ -n "$db_pass" ]; then
            # Check for active file locks (indicates file operations)
            local file_locks=$(mysql -u"$db_user" -p"$db_pass" "$db_name" -e "SELECT COUNT(*) FROM oc_file_locks WHERE lock > 0;" 2>/dev/null | tail -n1)
            if [ -n "$file_locks" ] && [ "$file_locks" -gt 0 ]; then
                echo_yellow "Found $file_locks active file locks in database"
                active_downloads=$((active_downloads + file_locks))
            fi
        fi
    fi
    
    # Check system load as an indicator
    local load_avg=$(uptime | awk -F'load average:' '{print $2}' | awk -F',' '{print $1}' | xargs)
    local cpu_count=$(nproc)
    if (( $(echo "$load_avg > $cpu_count" | bc -l) )); then
        echo_yellow "System load is high ($load_avg on $cpu_count CPUs), possibly due to active operations"
        active_downloads=$((active_downloads + 1))
    fi
    
    return $active_downloads
}

# cd to web dir
cd ${INSTALL_DIR}/

# Store the original script directory for later use (needed for selinux.sh)
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Get current installed version
echo_cyan "Checking current Nextcloud version..."
if [ -f ${INSTALL_DIR}/${NEXTCLOUD_DIR}/version.php ]; then
    current_version_string=$(grep "OC_VersionString" ${INSTALL_DIR}/${NEXTCLOUD_DIR}/version.php | sed "s/.*OC_VersionString = '\([^']*\)'.*/\1/")
    echo_green "Current installed version: $current_version_string"
    read current_major current_minor current_bugfix <<< $(parse_version "$current_version_string")
else
    echo_red "Could not find version.php in ${INSTALL_DIR}/${NEXTCLOUD_DIR}/"
    exit 1
fi

# Delete old files
echo_cyan "Removing old files..."
rm -f ${INSTALL_DIR}/latest.zip
rm -f ${INSTALL_DIR}/latest.zip.sha256
rm -f ${INSTALL_DIR}/latest.zip.asc
rm -rf ${INSTALL_DIR}/temp_version_check/

# Download the latest Nextcloud release
echo_cyan "Downloading the latest Nextcloud release..."
wget https://download.nextcloud.com/server/releases/latest.zip -O latest.zip
if [ $? -ne 0 ]; then
    echo_red "Failed to download latest.zip"
    exit 1
fi

# Create temp directory and extract version.php from the downloaded zip
echo_cyan "Extracting version information from latest.zip..."
mkdir -p ${INSTALL_DIR}/temp_version_check
unzip -j latest.zip "nextcloud/version.php" -d ${INSTALL_DIR}/temp_version_check/ > /dev/null 2>&1

if [ -f ${INSTALL_DIR}/temp_version_check/version.php ]; then
    latest_version_string=$(grep "OC_VersionString" ${INSTALL_DIR}/temp_version_check/version.php | sed "s/.*OC_VersionString = '\([^']*\)'.*/\1/")
    echo_green "Latest available version: $latest_version_string"
    read latest_major latest_minor latest_bugfix <<< $(parse_version "$latest_version_string")
else
    echo_red "Could not extract version.php from latest.zip"
    rm -rf ${INSTALL_DIR}/temp_version_check/
    exit 1
fi

# Clean up temp directory
rm -rf ${INSTALL_DIR}/temp_version_check/

# Compare versions
echo_cyan "\nVersion comparison:"
echo "Current: $current_major.$current_minor.$current_bugfix"
echo "Latest:  $latest_major.$latest_minor.$latest_bugfix"

if version_greater $latest_major $latest_minor $latest_bugfix $current_major $current_minor $current_bugfix; then
    echo_green "\nUpdate available! Proceeding with update..."
    
    # Check for active downloads
    check_active_downloads
    active_count=$?
    
    if [ $active_count -gt 0 ]; then
        echo_yellow "\nDetected $active_count indicators of active downloads/operations"
        echo_yellow "Waiting for operations to complete (maximum 1 hour)..."
        
        wait_time=0
        max_wait=3600  # 1 hour in seconds
        check_interval=60  # Check every minute
        
        while [ $wait_time -lt $max_wait ]; do
            sleep $check_interval
            wait_time=$((wait_time + check_interval))
            
            check_active_downloads
            active_count=$?
            
            if [ $active_count -eq 0 ]; then
                echo_green "No active downloads detected. Proceeding with update..."
                break
            else
                remaining_time=$(( (max_wait - wait_time) / 60 ))
                echo_yellow "Still $active_count active operations. Waiting... ($remaining_time minutes remaining)"
            fi
        done
        
        if [ $wait_time -ge $max_wait ]; then
            echo_red "Maximum wait time exceeded. Proceeding with update anyway..."
        fi
    else
        echo_green "No active downloads detected. Proceeding immediately..."
    fi
    
    echo ""
    
    # Continue with the rest of the update process
    
    # Turn off servers
    echo_cyan "Stopping ${WEB_SERVER}, ${PHP_SERVICE} and ${DATABASE_SERVICE}"
    systemctl stop ${WEB_SERVER} ${PHP_SERVICE} ${DATABASE_SERVICE}
    
    # Download checksum file
    echo_cyan "Downloading checksum file..."
    wget https://download.nextcloud.com/server/releases/latest.zip.sha256 -O latest.zip.sha256
    
    # Download the PGP signature
    echo_cyan "Downloading PGP signature..."
    wget https://download.nextcloud.com/server/releases/latest.zip.asc -O latest.zip.asc
    
    # Define Nextcloud's PGP key ID
    NEXTCLOUD_KEY_ID="28806A878AE423A28372792ED75899B9A724937A"
    
    # Check if Nextcloud's PGP key is already in the keyring
    echo_cyan "Checking for existing Nextcloud PGP key..."
    if ! gpg --list-keys "$NEXTCLOUD_KEY_ID" > /dev/null 2>&1; then
        # Import Nextcloud's PGP key
        echo_cyan "Importing Nextcloud's PGP key..."
        gpg --keyserver hkps://keys.openpgp.org --recv-keys "$NEXTCLOUD_KEY_ID"
        
        # Check if the key import was successful
        if [ $? -ne 0 ]; then
            echo_red "Failed to import PGP key. Exiting."
            exit 1
        fi
    else
        echo_cyan "Nextcloud PGP key already exists."
    fi
    
    # Verify the package with PGP
    echo_cyan "Verifying the package with PGP..."
    gpg --verify latest.zip.asc latest.zip
    if [ $? -ne 0 ]; then
        echo_red "PGP verification failed."
        exit 1
    fi
    echo_green "Download and verification completed successfully."
    
    # unzip
    echo_cyan "Unzipping the latest zip"
    unzip -o latest.zip
    
    # set dir permissions
    echo_cyan "Setting ${INSTALL_DIR}/${NEXTCLOUD_DIR}/ owner to wwwrun"
    chown -R wwwrun:wwwrun ${INSTALL_DIR}/${NEXTCLOUD_DIR}/
    chown  wwwrun:wwwrun ${INSTALL_DIR}/${NEXTCLOUD_DIR}
    
    # occ execute
    echo_cyan "Adding execute to occ"
    chmod +x ${INSTALL_DIR}/${NEXTCLOUD_DIR}/occ
    
    # Apply SELinux rules if enabled
    if [ "$SELINUX_ENABLED" = true ]; then
        echo_cyan "Applying SELinux rules..."
        if [ -f "$SCRIPT_DIR/selinux.sh" ]; then
            echo_cyan "Running $SCRIPT_DIR/selinux.sh"
            bash "$SCRIPT_DIR/selinux.sh"
            if [ $? -eq 0 ]; then
                echo_green "SELinux rules applied successfully"
            else
                echo_red "Warning: SELinux rule application failed, but continuing..."
            fi
        else
            echo_red "Warning: selinux.sh not found in $SCRIPT_DIR"
            echo_yellow "Skipping SELinux rule application"
        fi
    else
        echo_yellow "SELinux rule application is disabled (SELINUX_ENABLED=false)"
    fi
    
    # start servers
    echo_cyan "Starting ${WEB_SERVER}, ${PHP_SERVICE}, and ${DATABASE_SERVICE}"
    systemctl start ${WEB_SERVER} ${PHP_SERVICE} ${DATABASE_SERVICE}
    
    # wait for services to finish startup
    sleep 90
    
    # upgrade
    echo_cyan "Executing the upgrade"
    sudo -u wwwrun ${INSTALL_DIR}/${NEXTCLOUD_DIR}/occ upgrade
    
    echo_green "\nUpdate completed successfully!"
    echo_green "Updated from $current_version_string to $latest_version_string"
    
else
    echo_yellow "\nNo update needed. Current version ($current_version_string) is up to date."
    echo_cyan "Cleaning up downloaded files..."
    rm -f ${INSTALL_DIR}/latest.zip
    rm -f ${INSTALL_DIR}/latest.zip.sha256
    rm -f ${INSTALL_DIR}/latest.zip.asc
fi
