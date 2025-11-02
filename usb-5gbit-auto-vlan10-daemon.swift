#!/usr/bin/swift

import Foundation
import SystemConfiguration
import IOKit
import IOKit.usb

// MARK: - Configuration
struct DaemonConfig {
    // VLAN Configuration
    static let vlanInterface = "vlan10"
    static let vlanID = 10
    static let mtuSize = 1450 // Used to work at 1496, but now seems to need to be lower after setting up Zone Based Firewall rules (no idea if that's related but it worked right before setting them up)

    // USB Network Adapter Configuration
    // WisdPi USB 5G Ethernet (idVendor=3034/0x0BDA, idProduct=33111/0x8157)
    // To find your adapter's details, plug it in and run:
    // ioreg -p IOUSB -l -w 0 | grep -A 30 "Ethernet"
    static let targetVendorID: Int = 3034   // 0x0BDA (WisdPi)
    static let targetProductID: Int = 33111 // 0x8157 (USB 5G Ethernet)

    // Wait time after detection before configuring (allows driver to stabilize)
    static let stabilizationDelay: TimeInterval = 2.0
}

// MARK: - Logging
func log(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    print("[\(timestamp)] \(message)")
    fflush(stdout)
}

// MARK: - IOKit Callbacks

func deviceAdded(refCon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refCon = refCon else {
        // This should never happen
        log("ERROR: refCon is nil in deviceAdded, can't get reference to NetworkInterfaceManager to call handleDeviceAdded()")
        return
    }

    let manager = Unmanaged<NetworkInterfaceManager>.fromOpaque(refCon).takeUnretainedValue()
    manager.handleDeviceAdded()
}

func deviceRemoved(refCon: UnsafeMutableRawPointer?, iterator: io_iterator_t) {
    guard let refCon = refCon else {
        log("ERROR: refCon is nil in deviceRemoved, can't get reference to NetworkInterfaceManager to call handleDeviceRemoved()")
        return
    }

    let manager = Unmanaged<NetworkInterfaceManager>.fromOpaque(refCon).takeUnretainedValue()
    manager.handleDeviceRemoved()
}

// MARK: - Network Interface Manager
class NetworkInterfaceManager {
    private var configuredInterfaces: Set<String> = []
    private var interfaceToBSDName: [String: String] = [:] // Track which BSD name we configured
    private var notificationPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    init() {
        log("USB 5Gbit Auto VLAN10 Daemon started")
        log("Monitoring for 5Gbit USB Ethernet adapters using IOKit notifications...")
    }

    func start() {
        // Set up IOKit notification for USB device matching our vendor/product ID
        setupUSBNotifications()

        // Keep the daemon running
        RunLoop.main.run()
    }

    private func setupUSBNotifications() {
        // Create a notification port and add it to the run loop
        notificationPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notificationPort = notificationPort else {
            log("ERROR: Failed to create IONotificationPort")
            return
        }

        let runLoopSource = IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Set up notification for device arrival
        let matchingDictAdded = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matchingDictAdded[kUSBVendorID] = DaemonConfig.targetVendorID
        matchingDictAdded[kUSBProductID] = DaemonConfig.targetProductID

        let addResult = IOServiceAddMatchingNotification(
            notificationPort,
            kIOFirstMatchNotification,
            matchingDictAdded,
            deviceAdded,
            selfPtr,
            &addedIterator
        )

        guard addResult == KERN_SUCCESS else {
            log("ERROR: Failed to add matching notification for device arrival: \(addResult)")
            return
        }

        // Process any devices that are already connected
        processExistingDevices(iterator: addedIterator)

        // Set up notification for device removal
        let matchingDictRemoved = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matchingDictRemoved[kUSBVendorID] = DaemonConfig.targetVendorID
        matchingDictRemoved[kUSBProductID] = DaemonConfig.targetProductID

        let removeResult = IOServiceAddMatchingNotification(
            notificationPort,
            kIOTerminatedNotification,
            matchingDictRemoved,
            deviceRemoved,
            selfPtr,
            &removedIterator
        )

        guard removeResult == KERN_SUCCESS else {
            log("ERROR: Failed to add matching notification for device removal: \(removeResult)")
            return
        }

        // Process the removal iterator to arm it
        processExistingDevices(iterator: removedIterator)

        log("IOKit notifications setup complete (monitoring both arrival and removal)")
    }

    private func processExistingDevices(iterator: io_iterator_t) {
        while case let device = IOIteratorNext(iterator), device != 0 {
            IOObjectRelease(device)
        }
    }

    func handleDeviceAdded() {
        // Process the notification iterator
        while case let device = IOIteratorNext(addedIterator), device != 0 {
            log("Target USB device detected (VID:\(DaemonConfig.targetVendorID) PID:\(DaemonConfig.targetProductID))")

            // Wait for the network interface to appear and stabilize
            DispatchQueue.main.asyncAfter(deadline: .now() + DaemonConfig.stabilizationDelay) { [weak self] in
                self?.findAndConfigureNetworkInterface()
            }

            IOObjectRelease(device)
        }
    }

    func handleDeviceRemoved() {
        // Process the notification iterator
        while case let device = IOIteratorNext(removedIterator), device != 0 {
            log("Target USB device removed (VID:\(DaemonConfig.targetVendorID) PID:\(DaemonConfig.targetProductID))")

            // Clean up the VLAN interface
            cleanupVLAN()

            IOObjectRelease(device)
        }
    }

    private func findAndConfigureNetworkInterface() {
        // Find the BSD name of the network interface that belongs to our USB device
        guard let bsdName = findBSDNameForUSBDevice() else {
            log("WARNING: USB device detected but no matching network interface found yet")
            return
        }

        // Skip already configured interfaces
        if configuredInterfaces.contains(bsdName) {
            log("Interface \(bsdName) already configured, skipping")
            return
        }

        log("Found network interface \(bsdName) for target USB device")
        configureVLAN(for: bsdName)
        configuredInterfaces.insert(bsdName)
    }

    private func findBSDNameForUSBDevice() -> String? {
        // Find our target USB device
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matchingDict[kUSBVendorID] = DaemonConfig.targetVendorID
        matchingDict[kUSBProductID] = DaemonConfig.targetProductID

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)

        guard result == KERN_SUCCESS else {
            log("ERROR: Failed to get matching USB services")
            return nil
        }

        defer {
            IOObjectRelease(iterator)
        }

        let usbDevice = IOIteratorNext(iterator)
        guard usbDevice != 0 else {
            log("ERROR: Target USB device not found")
            return nil
        }

        defer {
            IOObjectRelease(usbDevice)
        }

        // Traverse down the IOKit registry to find the network interface
        // The path is typically: USBDevice -> IOUSBHostInterface -> IOEthernetInterface -> BSD Name
        return findBSDNameInChildren(of: usbDevice)
    }

    private func findBSDNameInChildren(of service: io_service_t) -> String? {
        // Check if this service has a BSD name
        if let bsdName = getPropertyString(service: service, key: "BSD Name") {
            log("Found BSD Name: \(bsdName)")
            return bsdName
        }

        // Search children recursively
        var childIterator: io_iterator_t = 0
        let result = IORegistryEntryGetChildIterator(service, kIOServicePlane, &childIterator)

        guard result == KERN_SUCCESS else {
            return nil
        }

        defer {
            IOObjectRelease(childIterator)
        }

        while case let child = IOIteratorNext(childIterator), child != 0 {
            defer {
                IOObjectRelease(child)
            }

            if let bsdName = findBSDNameInChildren(of: child) {
                return bsdName
            }
        }

        return nil
    }

    private func getPropertyString(service: io_service_t, key: String) -> String? {
        guard let property = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0) else {
            return nil
        }

        let value = property.takeRetainedValue()

        if CFGetTypeID(value) == CFStringGetTypeID() {
            return value as? String
        }

        return nil
    }

    private func configureVLAN(for interface: String) {
        log("Configuring VLAN for interface: \(interface)")

        // Execute the configuration commands
        let commands: [(String, [String])] = [
            ("/sbin/ifconfig", [DaemonConfig.vlanInterface, "create"]),
            ("/sbin/ifconfig", [DaemonConfig.vlanInterface, "vlan", "\(DaemonConfig.vlanID)", "vlandev", interface]),
            ("/sbin/ifconfig", [DaemonConfig.vlanInterface, "up"]),
            ("/usr/sbin/ipconfig", ["set", DaemonConfig.vlanInterface, "DHCP"]),
            ("/sbin/ifconfig", [DaemonConfig.vlanInterface, "mtu", "\(DaemonConfig.mtuSize)"])
        ]

        for (command, args) in commands {
            let result = executeCommand(command, arguments: args)
            if !result.success {
                log("Error executing: \(command) \(args.joined(separator: " "))")
                log("Error output: \(result.error)")

                // If VLAN already exists, destroy and recreate
                if result.error.contains("already exists") {
                    log("VLAN interface already exists, destroying and recreating...")
                    _ = executeCommand("/sbin/ifconfig", arguments: [DaemonConfig.vlanInterface, "destroy"])

                    // Retry all commands
                    for (cmd, cmdArgs) in commands {
                        let retryResult = executeCommand(cmd, arguments: cmdArgs)
                        if !retryResult.success {
                            log("Retry failed: \(cmd) \(cmdArgs.joined(separator: " "))")
                            log("Error: \(retryResult.error)")
                        }
                    }
                    break
                }
            } else {
                log("Success: \(command) \(args.joined(separator: " "))")
            }
        }

        log("VLAN configuration complete for \(interface)")
    }

    private func cleanupVLAN() {
        log("Cleaning up VLAN interface: \(DaemonConfig.vlanInterface)")

        // Destroy the VLAN interface
        let result = executeCommand("/sbin/ifconfig", arguments: [DaemonConfig.vlanInterface, "destroy"])

        if result.success {
            log("Successfully destroyed VLAN interface \(DaemonConfig.vlanInterface)")
        } else {
            // Don't log an error if the interface doesn't exist (which is fine)
            if !result.error.contains("does not exist") && !result.error.isEmpty {
                log("Error destroying VLAN interface: \(result.error)")
            } else {
                log("VLAN interface \(DaemonConfig.vlanInterface) already removed or doesn't exist")
            }
        }

        // Clear our tracking
        configuredInterfaces.removeAll()
        interfaceToBSDName.removeAll()
    }

    private func executeCommand(_ command: String, arguments: [String]) -> (success: Bool, output: String, error: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: command)
        task.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = errorPipe

        do {
            try task.run()
            task.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

            let output = String(data: outputData, encoding: .utf8) ?? ""
            let error = String(data: errorData, encoding: .utf8) ?? ""

            let success = task.terminationStatus == 0
            return (success, output, error)
        } catch {
            return (false, "", "Failed to execute: \(error.localizedDescription)")
        }
    }
}

// MARK: - Signal Handling
class SignalHandler {
    static func setup() {
        // Handle SIGTERM gracefully
        signal(SIGTERM) { signal in
            print("Received SIGTERM, shutting down gracefully...")
            exit(0)
        }

        // Handle SIGINT (Ctrl+C) for testing
        signal(SIGINT) { signal in
            print("Received SIGINT, shutting down gracefully...")
            exit(0)
        }
    }
}

// MARK: - Main Entry Point
SignalHandler.setup()

let manager = NetworkInterfaceManager()
manager.start()
