#!/bin/bash

# USB 5Gbit Auto VLAN10 Daemon - Uninstallation Script
# This script removes the daemon and all associated files

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
DAEMON_NAME="usb-5gbit-auto-vlan10-daemon"
PLIST_NAME="com.local.usb-5gbit-auto-vlan10-daemon"
INSTALL_DIR="/usr/local/bin"
LAUNCHDAEMON_DIR="/Library/LaunchDaemons"
LOG_DIR="/var/log"

echo -e "${YELLOW}USB 5Gbit Auto VLAN10 Daemon - Uninstallation${NC}"
echo "======================================"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Uninstallation requires root privileges${NC}"
    echo "Please run: sudo ./uninstall.sh"
    exit 1
fi

# Unload daemon if running
echo -e "\n${YELLOW}Step 1: Stopping daemon...${NC}"
if launchctl list | grep -q "${PLIST_NAME}"; then
    launchctl unload "${LAUNCHDAEMON_DIR}/${PLIST_NAME}.plist" 2>/dev/null
    echo -e "${GREEN}✓ Daemon stopped${NC}"
else
    echo "Daemon not running"
fi

# Remove plist
echo -e "\n${YELLOW}Step 2: Removing LaunchDaemon configuration...${NC}"
if [ -f "${LAUNCHDAEMON_DIR}/${PLIST_NAME}.plist" ]; then
    rm "${LAUNCHDAEMON_DIR}/${PLIST_NAME}.plist"
    echo -e "${GREEN}✓ Configuration removed${NC}"
else
    echo "Configuration file not found (already removed?)"
fi

# Remove binary
echo -e "\n${YELLOW}Step 3: Removing daemon binary...${NC}"
if [ -f "${INSTALL_DIR}/${DAEMON_NAME}" ]; then
    rm "${INSTALL_DIR}/${DAEMON_NAME}"
    echo -e "${GREEN}✓ Binary removed${NC}"
else
    echo "Binary not found (already removed?)"
fi

# Ask about log files
echo -e "\n${YELLOW}Step 4: Log files...${NC}"
read -p "Do you want to remove log files? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    if [ -f "${LOG_DIR}/${DAEMON_NAME}.log" ]; then
        rm "${LOG_DIR}/${DAEMON_NAME}.log"
    fi
    if [ -f "${LOG_DIR}/${DAEMON_NAME}-error.log" ]; then
        rm "${LOG_DIR}/${DAEMON_NAME}-error.log"
    fi
    echo -e "${GREEN}✓ Log files removed${NC}"
else
    echo "Log files kept at:"
    echo "  ${LOG_DIR}/${DAEMON_NAME}.log"
    echo "  ${LOG_DIR}/${DAEMON_NAME}-error.log"
fi

echo -e "\n${GREEN}Uninstallation complete!${NC}"
echo ""
echo "The daemon has been removed from your system."
echo "To reinstall, run: sudo ./build.sh install"
