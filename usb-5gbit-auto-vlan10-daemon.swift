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

    // Poll interval for checking new interfaces (in seconds)
    static let pollInterval: TimeInterval = 1.0

    // Wait time after detection before configuring (allows driver to stabilize)
    static let stabilizationDelay: TimeInterval = 2.0
}

// MARK: - Network Interface Manager
class NetworkInterfaceManager {
    private var knownInterfaces: Set<String> = []
    private var configuredInterfaces: Set<String> = []
    private var timer: Timer?

    init() {
        log("USB 5Gbit Auto VLAN10 Daemon started")
        log("Monitoring for 5Gbit USB Ethernet adapters...")

        // Initialize known interfaces
        updateKnownInterfaces()
    }

    func start() {
        // Start monitoring for new interfaces
        timer = Timer.scheduledTimer(
            withTimeInterval: DaemonConfig.pollInterval,
            repeats: true
        ) { [weak self] _ in
            self?.checkForNewInterfaces()
        }

        // Keep the daemon running
        RunLoop.main.run()
    }

    private func updateKnownInterfaces() {
        knownInterfaces = Set(getCurrentInterfaces())
        log("Currently known interfaces: \(knownInterfaces.sorted().joined(separator: ", "))")
    }

    private func getCurrentInterfaces() -> [String] {
        var interfaces: [String] = []

        // Get all network interfaces from SystemConfiguration
        guard let allInterfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return interfaces
        }

        for interface in allInterfaces {
            if let bsdName = SCNetworkInterfaceGetBSDName(interface) as String? {
                interfaces.append(bsdName)
            }
        }

        return interfaces
    }

    private func checkForNewInterfaces() {
        let currentInterfaces = Set(getCurrentInterfaces())
        let newInterfaces = currentInterfaces.subtracting(knownInterfaces)

        for interface in newInterfaces {
            if isCorrectUSBEthernetInterface(interface) && !configuredInterfaces.contains(interface) {
                log("New USB Ethernet interface detected: \(interface)")

                // Wait for interface to stabilize before configuring
                DispatchQueue.main.asyncAfter(deadline: .now() + DaemonConfig.stabilizationDelay) { [weak self] in
                    self?.configureVLAN(for: interface)
                }

                configuredInterfaces.insert(interface)
            }
        }

        // Update known interfaces
        knownInterfaces = currentInterfaces
    }

    private func isCorrectUSBEthernetInterface(_ bsdName: String) -> Bool {
        // First check if it's an Ethernet interface
        guard let allInterfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else {
            return false
        }

        var isEthernet = false
        for interface in allInterfaces {
            if let name = SCNetworkInterfaceGetBSDName(interface) as String?,
               name == bsdName {
                let interfaceType = SCNetworkInterfaceGetInterfaceType(interface) as String?
                if interfaceType == "Ethernet" {
                    isEthernet = true
                    break
                }
            }
        }

        if !isEthernet {
            return false
        }

        // Now check if it's the specific USB device we're looking for
        // Query IOKit for USB devices matching our vendor/product ID
        let matchingDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matchingDict[kUSBVendorID] = DaemonConfig.targetVendorID
        matchingDict[kUSBProductID] = DaemonConfig.targetProductID

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDict, &iterator)

        guard result == KERN_SUCCESS else {
            return false
        }

        defer {
            IOObjectRelease(iterator)
        }

        // Check if we found any matching USB devices
        let usbDevice = IOIteratorNext(iterator)
        if usbDevice != 0 {
            IOObjectRelease(usbDevice)
            log("Interface \(bsdName) identified as target WisdPi USB 5G Ethernet (VID:\(DaemonConfig.targetVendorID) PID:\(DaemonConfig.targetProductID))")
            return true
        }

        return false
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

    private func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        print("[\(timestamp)] \(message)")
        fflush(stdout)
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
