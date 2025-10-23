# Nextcloud Update Script

A bash script to automate Nextcloud updates with version checking, PGP verification, and intelligent handling of active downloads.

## Features

- **Version comparison**: Checks current version against latest release before updating
- **Active download detection**: Monitors and waits for ongoing file transfers before updating
- **PGP verification**: Verifies download integrity using Nextcloud's official PGP signature
- **Service management**: Handles graceful shutdown and restart of web services
- **SELinux support**: Optional SELinux context application
- **Configurable**: Easy customization of installation paths and service names

## Requirements

- Linux system with bash
- Root/sudo privileges
- Nextcloud already installed
- Required commands: `wget`, `unzip`, `gpg`, `ss`, `mysql` (optional)
- Services: web server (nginx/apache), PHP-FPM, database (MariaDB/MySQL)

## Configuration

Edit the configuration variables at the top of the script:

```bash
INSTALL_DIR="/web"              # Base installation directory
NEXTCLOUD_DIR="nextcloud"       # Nextcloud subdirectory name
WEB_SERVER="nginx"              # Web server service name
PHP_SERVICE="php-fpm.service"   # PHP-FPM service name
DATABASE_SERVICE="mariadb"      # Database service name
SELINUX_ENABLED=true            # Enable/disable SELinux rule application
```

## Usage

1. Download the script:
```bash
wget https://raw.githubusercontent.com/yourusername/nextcloud-update/main/nextcloud-update.sh
chmod +x nextcloud-update.sh
```

2. Configure the variables (if needed)

3. Run the script as root:
```bash
sudo ./nextcloud-update.sh
```

## What It Does

1. **Version Check**: Compares your current Nextcloud version with the latest release
2. **Download Detection**: Checks for active downloads and waits up to 1 hour if detected
3. **Service Shutdown**: Stops web server, PHP-FPM, and database services
4. **Download & Verify**: Downloads latest Nextcloud and verifies PGP signature
5. **Extract & Update**: Extracts files and sets proper permissions
6. **SELinux Application**: Applies SELinux contexts if enabled
7. **Service Restart**: Starts all services and executes the Nextcloud upgrade command

## Active Download Detection

The script checks multiple indicators:
- HTTP/HTTPS connections with active data transfer
- Busy PHP-FPM processes
- Database file locks
- System load average

If active operations are detected, the script waits up to 1 hour before proceeding with the update.

## Security Notes

- Always verify the PGP key fingerprint matches: `28806A878AE423A28372792ED75899B9A724937A`
- Review the script before running it with root privileges
- Keep backups before updating
- Test on non-production systems first

## SELinux Support

If you use SELinux, create a `selinux.sh` script in the same directory to apply proper contexts. The script will execute it automatically if `SELINUX_ENABLED=true`.

## Troubleshooting

**Script exits saying no update needed**
- This is normal if you're already on the latest version

**PGP verification fails**
- Check your internet connection
- Ensure GPG is installed and configured properly

**Services fail to start**
- Check service logs: `journalctl -xe`
- Verify service names in configuration match your system

## Contributing

Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

## License

MIT

## Disclaimer

This script is provided as-is. Always maintain backups and test in a non-production environment first. The author is not responsible for any data loss or system issues.
