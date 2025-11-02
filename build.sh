#!/bin/bash

# USB 5Gbit Auto VLAN10 Daemon - Build and Installation Script
# This script compiles the Swift daemon and installs it as a LaunchDaemon

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
DAEMON_NAME="usb-5gbit-auto-vlan10-daemon"
PLIST_NAME="com.local.usb-5gbit-auto-vlan10-daemon"
BUILD_DIR="build"
INSTALL_DIR="/usr/local/bin"
LAUNCHDAEMON_DIR="/Library/LaunchDaemons"
LOG_DIR="/var/log"

echo -e "${GREEN}USB 5Gbit Auto VLAN10 Daemon - Build and Installation${NC}"
echo "=============================================="

# Check if running as root for installation
if [ "$EUID" -ne 0 ] && [ "$1" == "install" ]; then
    echo -e "${RED}Error: Installation requires root privileges${NC}"
    echo "Please run: sudo ./build.sh install"
    exit 1
fi

# Create build directory
echo -e "\n${YELLOW}Step 1: Creating build directory...${NC}"
mkdir -p "${BUILD_DIR}"
echo -e "${GREEN}✓ Build directory created${NC}"

# Build the daemon
echo -e "\n${YELLOW}Step 2: Compiling Swift daemon...${NC}"
if [ ! -f "${DAEMON_NAME}.swift" ]; then
    echo -e "${RED}Error: ${DAEMON_NAME}.swift not found${NC}"
    exit 1
fi

swiftc -framework Foundation -framework SystemConfiguration -framework IOKit -o "${BUILD_DIR}/${DAEMON_NAME}" "${DAEMON_NAME}.swift"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Compilation successful${NC}"
    echo "Binary created at: ${BUILD_DIR}/${DAEMON_NAME}"
else
    echo -e "${RED}✗ Compilation failed${NC}"
    exit 1
fi

# Make executable
chmod +x "${BUILD_DIR}/${DAEMON_NAME}"

# If only building (not installing), stop here
if [ "$1" != "install" ]; then
    echo -e "\n${GREEN}Build complete!${NC}"
    echo "To install the daemon, run: sudo ./build.sh install"
    exit 0
fi

# Installation steps (require root)
echo -e "\n${YELLOW}Step 3: Installing daemon...${NC}"

# Unload existing daemon if running
if launchctl list | grep -q "${PLIST_NAME}"; then
    echo "Unloading existing daemon..."
    launchctl unload "${LAUNCHDAEMON_DIR}/${PLIST_NAME}.plist" 2>/dev/null || true
fi

# Copy binary to install directory
echo "Copying binary from ${BUILD_DIR}/${DAEMON_NAME} to ${INSTALL_DIR}/${DAEMON_NAME}..."
cp "${BUILD_DIR}/${DAEMON_NAME}" "${INSTALL_DIR}/${DAEMON_NAME}"
chown root:wheel "${INSTALL_DIR}/${DAEMON_NAME}"
chmod 755 "${INSTALL_DIR}/${DAEMON_NAME}"

# Copy plist to LaunchDaemons directory
echo "Installing LaunchDaemon configuration..."
if [ ! -f "${PLIST_NAME}.plist" ]; then
    echo -e "${RED}Error: ${PLIST_NAME}.plist not found${NC}"
    exit 1
fi

cp "${PLIST_NAME}.plist" "${LAUNCHDAEMON_DIR}/${PLIST_NAME}.plist"
chown root:wheel "${LAUNCHDAEMON_DIR}/${PLIST_NAME}.plist"
chmod 644 "${LAUNCHDAEMON_DIR}/${PLIST_NAME}.plist"

# Create log files if they don't exist
touch "${LOG_DIR}/${DAEMON_NAME}.log"
touch "${LOG_DIR}/${DAEMON_NAME}-error.log"
chmod 644 "${LOG_DIR}/${DAEMON_NAME}.log"
chmod 644 "${LOG_DIR}/${DAEMON_NAME}-error.log"

# Load the daemon
echo -e "\n${YELLOW}Step 4: Loading daemon...${NC}"
launchctl load "${LAUNCHDAEMON_DIR}/${PLIST_NAME}.plist"

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✓ Daemon loaded successfully${NC}"
else
    echo -e "${RED}✗ Failed to load daemon${NC}"
    exit 1
fi

# Verify daemon is running
sleep 2
if launchctl list | grep -q "${PLIST_NAME}"; then
    echo -e "${GREEN}✓ Daemon is running${NC}"
else
    echo -e "${RED}✗ Daemon is not running${NC}"
    echo "Check logs for errors:"
    echo "  tail -f ${LOG_DIR}/${DAEMON_NAME}.log"
    echo "  tail -f ${LOG_DIR}/${DAEMON_NAME}-error.log"
    exit 1
fi

echo -e "\n${GREEN}Installation complete!${NC}"
echo ""
echo "Daemon Status:"
echo "  Name: ${PLIST_NAME}"
echo "  Binary: ${INSTALL_DIR}/${DAEMON_NAME}"
echo "  Config: ${LAUNCHDAEMON_DIR}/${PLIST_NAME}.plist"
echo "  Logs: ${LOG_DIR}/${DAEMON_NAME}.log"
echo ""
echo "Useful commands:"
echo "  View logs:     tail -f ${LOG_DIR}/${DAEMON_NAME}.log"
echo "  Check status:  sudo launchctl list | grep ${PLIST_NAME}"
echo "  Restart:       sudo launchctl unload ${LAUNCHDAEMON_DIR}/${PLIST_NAME}.plist && sudo launchctl load ${LAUNCHDAEMON_DIR}/${PLIST_NAME}.plist"
echo "  Uninstall:     sudo ./uninstall.sh"
