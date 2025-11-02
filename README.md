# USB 5Gbit Auto VLAN10 Daemon

A macOS LaunchDaemon that automatically detects when a specific WisdPi USB 5G Ethernet adapter (VID:3034 PID:33111) is plugged in and configures a VLAN 10 interface with custom settings.

**WARNING YOU PROBABLY DON'T NEED OR WANT THIS!**

I created this for my own very niche use case where I have a Unifi network with 1gbit switches, to which is attached an unmanaged 10Gbit switch which connects my home server. The VMs on the server are on VLAN10 and the Unifi port the switch is connected to defaults to VLAN1. I then connect to the unmanaged switch from my MacBook using a 5gbit USB network adapter into a 10/5/2.5gbit SFP adapter. In order to get full speed and full working networking (to prevent inter-VLAN routing via the main router at 1gbit speed), I also need my Mac to tag packets as VLAN10, so this daemon watches for the network adapter to be connected and sets up the VLAN interface. The reduction of the MTU to 1450 allows SSH traffic to work because with the VLAN tagging it fails due to packets being too large.

I could avoid all this hassle by disabling the VLAN tagging on my server and setting the Unifi port to default to VLAN10, but then I'd have to redo all the networking on my server and I don't want to do that since I only use this adapter occasionally to transfer large files quickly. Otherwise I just connect over wifi at sub-1gbit speeds.

So instead of all that I vibe-coded this thing with Claude Code. Code written by Claude, reviewed/cleaned up by me. Since this is basically all AI written (except this README section), I've used the Unlicense to make it public domain.

## Overview

This daemon runs in the background and monitors for the specific WisdPi USB 5G Ethernet adapter. When it is detected, it automatically:

1. Creates a VLAN interface (`vlan10`)
2. Configures VLAN 10 on the detected USB network interface
3. Brings the VLAN interface up
4. Configures DHCP on the VLAN interface
5. Sets MTU to 1450

The daemon starts automatically on boot and runs invisibly in the background with root privileges.

## Features

- **Specific Device Detection**: Only detects and configures the WisdPi USB 5G Ethernet adapter (VID:3034 PID:33111)
- **Automatic Detection**: Detects the adapter within seconds of being plugged in
- **Auto-start**: Launches automatically on system boot via LaunchDaemon
- **Background Operation**: Runs invisibly with no user interaction required
- **Robust**: Restarts automatically if it crashes
- **Configurable**: Easy to customize VLAN ID, MTU, and target device
- **Clean Logging**: Detailed logs for troubleshooting

## Requirements

- macOS 10.15 or later
- Swift compiler (included with Xcode Command Line Tools)
- Root/administrator access for installation
- WisdPi USB 5G Ethernet adapter (VID:3034 PID:33111)

## Installation

### Step 1: Install Xcode Command Line Tools (if not already installed)

```bash
xcode-select --install
```

### Step 2: Build the Daemon

```bash
# Just compile (no installation)
./build.sh
```

### Step 3: Install the Daemon

```bash
# Install and start the daemon
sudo ./build.sh install
```

The installation script will:
- Compile the Swift code
- Install the binary to `/usr/local/bin/usb-5gbit-auto-vlan10-daemon`
- Install the LaunchDaemon plist to `/Library/LaunchDaemons/`
- Set correct permissions
- Load and start the daemon

### Step 4: Verify Installation

```bash
# Check if daemon is running
sudo launchctl list | grep usb-5gbit-auto-vlan10-daemon

# View logs
tail -f /var/log/usb-5gbit-auto-vlan10-daemon.log
```

## Customization

### Configuration Options

**Device-Specific Detection:**

By default, the daemon is configured to detect only the WisdPi USB 5G Ethernet adapter:
- Vendor ID: 3034 (0x0BDA)
- Product ID: 33111 (0x8157)

To target a different USB Ethernet adapter, you'll need to find its vendor and product IDs:

```bash
# Plug in your USB network adapter, then run:
ioreg -p IOUSB -l -w 0 | grep -A 30 "Ethernet"

# Look for "idVendor" and "idProduct" in the output
```

Then update the values in `usb-5gbit-auto-vlan10-daemon.swift`:

```swift
static let targetVendorID: Int = 3034   // Your vendor ID
static let targetProductID: Int = 33111 // Your product ID
```

**VLAN Configuration:**

Edit `usb-5gbit-auto-vlan10-daemon.swift` to customize the following settings in the `DaemonConfig` struct:

```swift
struct DaemonConfig {
    // VLAN Configuration
    static let vlanInterface = "vlan10"     // VLAN interface name
    static let vlanID = 10                  // VLAN ID (1-4094)
    static let mtuSize = 1496               // MTU size

    // USB Device Detection
    static let targetVendorID: Int = 3034   // USB Vendor ID
    static let targetProductID: Int = 33111 // USB Product ID

    // Detection timing
    static let pollInterval: TimeInterval = 1.0              // Check interval (seconds)
    static let stabilizationDelay: TimeInterval = 2.0        // Wait before configuring
}
```

#### Common Customizations

**Change VLAN ID:**
```swift
static let vlanID = 20  // Use VLAN 20 instead
```

**Change VLAN interface name:**
```swift
static let vlanInterface = "vlan20"
```

**Change MTU:**
```swift
static let mtuSize = 1500  // Standard Ethernet MTU
```

**Use Static IP instead of DHCP:**

Modify the `configureVLAN` function to replace the DHCP command:

```swift
// Replace this line:
("/usr/sbin/ipconfig", ["set", DaemonConfig.vlanInterface, "DHCP"]),

// With this:
("/sbin/ifconfig", [DaemonConfig.vlanInterface, "192.168.10.100", "netmask", "255.255.255.0"]),
```

**Target Different USB Adapter:**

To target a different USB Ethernet adapter, find its vendor/product ID using `ioreg` and update:

```swift
static let targetVendorID: Int = YOUR_VENDOR_ID
static let targetProductID: Int = YOUR_PRODUCT_ID
```

### Rebuild After Changes

After making any changes to the Swift code:

```bash
# Rebuild and reinstall
sudo ./build.sh install
```

## Usage

### Monitoring

View real-time logs:
```bash
tail -f /var/log/usb-5gbit-auto-vlan10-daemon.log
```

View error logs:
```bash
tail -f /var/log/usb-5gbit-auto-vlan10-daemon-error.log
```

### Control Commands

Check if daemon is running:
```bash
sudo launchctl list | grep com.local.usb-5gbit-auto-vlan10-daemon
```

Restart the daemon:
```bash
sudo launchctl unload /Library/LaunchDaemons/com.local.usb-5gbit-auto-vlan10-daemon.plist
sudo launchctl load /Library/LaunchDaemons/com.local.usb-5gbit-auto-vlan10-daemon.plist
```

Stop the daemon:
```bash
sudo launchctl unload /Library/LaunchDaemons/com.local.usb-5gbit-auto-vlan10-daemon.plist
```

Start the daemon:
```bash
sudo launchctl load /Library/LaunchDaemons/com.local.usb-5gbit-auto-vlan10-daemon.plist
```

### Verify VLAN Configuration

After plugging in your USB network adapter, verify the VLAN is configured:

```bash
# Check if vlan10 interface exists
ifconfig vlan10

# You should see output like:
# vlan10: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> mtu 1496
#         options=3<RXCSUM,TXCSUM>
#         ether xx:xx:xx:xx:xx:xx
#         inet 192.168.x.x netmask 0xffffff00 broadcast 192.168.x.255
#         vlan: 10 vlanpif: en15
```

## Uninstallation

Run the uninstall script:

```bash
sudo ./uninstall.sh
```

Or manually remove:

```bash
# Unload the daemon
sudo launchctl unload /Library/LaunchDaemons/com.local.usb-5gbit-auto-vlan10-daemon.plist

# Remove files
sudo rm /Library/LaunchDaemons/com.local.usb-5gbit-auto-vlan10-daemon.plist
sudo rm /usr/local/bin/usb-5gbit-auto-vlan10-daemon

# Optional: Remove logs
sudo rm /var/log/usb-5gbit-auto-vlan10-daemon.log
sudo rm /var/log/usb-5gbit-auto-vlan10-daemon-error.log
```

## Troubleshooting

### Daemon Not Starting

1. Check the error log:
   ```bash
   cat /var/log/usb-5gbit-auto-vlan10-daemon-error.log
   ```

2. Verify plist syntax:
   ```bash
   plutil -lint /Library/LaunchDaemons/com.local.usb-5gbit-auto-vlan10-daemon.plist
   ```

3. Check permissions:
   ```bash
   ls -la /Library/LaunchDaemons/com.local.usb-5gbit-auto-vlan10-daemon.plist
   ls -la /usr/local/bin/usb-5gbit-auto-vlan10-daemon
   ```

### USB Adapter Not Detected

1. Verify the adapter is recognized by macOS:
   ```bash
   ifconfig -a
   # Look for interfaces like en1, en2, en3, etc.
   ```

2. Check the daemon logs:
   ```bash
   tail -f /var/log/usb-5gbit-auto-vlan10-daemon.log
   # You should see messages about detected interfaces
   ```

3. Verify the USB device vendor/product IDs match:
   ```bash
   ioreg -p IOUSB -l -w 0 | grep -A 30 "Ethernet"
   # Look for idVendor (should be 3034) and idProduct (should be 33111)
   ```

4. If you have a different adapter, update the vendor/product IDs in the config

### VLAN Configuration Fails

1. Check if commands work manually:
   ```bash
   sudo ifconfig vlan10 create
   sudo ifconfig vlan10 vlan 10 vlandev en15
   sudo ifconfig vlan10 up
   sudo ipconfig set vlan10 DHCP
   sudo ifconfig vlan10 mtu 1496
   ```

2. If "already exists" error, destroy existing VLAN:
   ```bash
   sudo ifconfig vlan10 destroy
   ```

3. Check if parent interface is correct:
   ```bash
   ifconfig -a | grep "^en"
   ```

### Interface Name Changes

macOS may assign different interface names (en1, en2, en15, etc.) depending on what's plugged in. The daemon automatically detects the correct interface, but you can verify:

```bash
# See all interfaces
ifconfig -a

# See VLAN configuration
ifconfig vlan10 | grep vlanpif
```

## Technical Details

### Architecture

- **Language**: Swift
- **Frameworks**: Foundation, SystemConfiguration
- **Detection Method**: Polling SystemConfiguration for new network interfaces
- **Execution**: LaunchDaemon running as root
- **Logging**: Standard output/error to `/var/log/`

### How It Works

1. Daemon starts on system boot via LaunchDaemon
2. Initializes list of currently known network interfaces
3. Polls every second for new interfaces using SystemConfiguration framework
4. Identifies new Ethernet interfaces and checks USB vendor/product ID using IOKit
5. Only proceeds if the device matches WisdPi USB 5G Ethernet (VID:3034 PID:33111)
6. Waits 2 seconds for driver stabilization
7. Executes VLAN configuration commands as root
8. Tracks configured interfaces to avoid duplicate configuration

### Security Considerations

- Runs as root (required for network configuration)
- Only modifies network interfaces (no other system changes)
- Logs all actions for audit trail
- No network communication or external dependencies

## Files

- `usb-5gbit-auto-vlan10-daemon.swift` - Main daemon source code
- `com.local.usb-5gbit-auto-vlan10-daemon.plist` - LaunchDaemon configuration
- `build.sh` - Build and installation script
- `uninstall.sh` - Uninstallation script
- `LICENSE.md` - Unlicense (Public Domain)
- `README.md` - This file

## License

This project is released into the public domain under the Unlicense - see the [LICENSE.md](LICENSE.md) file for details.

The Unlicense is the most permissive option, dedicating the work to the public domain:
- Use the software for any purpose without restrictions
- No copyright or attribution requirements
- No warranty or liability
- Complete freedom to use, modify, and distribute

For more information, visit [unlicense.org](https://unlicense.org)

## Support

For issues or questions:
1. Check the logs: `/var/log/usb-5gbit-auto-vlan10-daemon.log`
2. Verify configuration in `usb-5gbit-auto-vlan10-daemon.swift`
3. Test VLAN commands manually

## Future Enhancements

Potential improvements:
- Configuration file (JSON/plist) instead of hardcoded values
- Support for multiple USB adapters with different configurations
- Notification when VLAN is configured
- Web interface for configuration
- Automatic cleanup when adapter is unplugged (though macOS handles this)

---

**Note**: This daemon is designed for a specific use case. Always test in a non-production environment first and ensure you understand the network configuration being applied.
