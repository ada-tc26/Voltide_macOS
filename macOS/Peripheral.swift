import Foundation
import IOKit
import IOKit.hid

struct ComponentLevel {
    let label: String
    let percent: Int
    var readAt: Date?
    var stale = false
}

struct Peripheral: Identifiable {
    let id: String
    var name: String
    let transport: String
    var percent: Int?
    var charging: Bool?
    var state = "已连接"

    var componentLevels: [ComponentLevel] = []
    var bluetoothType: String?
    var readAt: Date?
    var lastSeen: Date?
    var stale = false
    var aliasKey: String?

    var statusText: String {
        if transport == "蓝牙" {
            var parts = [transport]
            if charging == true { parts.append("充电中") }
            if state != "已连接" { parts.append(state) }
            return parts.joined(separator: " · ")
        }
        return state != "已连接" ? state : charging == true ? "充电中" : transport
    }

    var deviceSymbol: String {
        let label = (name + " " + (bluetoothType ?? "")).lowercased()
        if transport == "游戏手柄" || label.contains("gamepad") || label.contains("controller") || label.contains("joystick") { return "gamecontroller" }
        if label.contains("keyboard") || label.contains("键盘") { return "keyboard" }
        if label.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if label.contains("head") || label.contains("耳机") || label.contains("airpods") { return "headphones" }
        if label.contains("mouse") || label.contains("鼠标") || id.hasPrefix("usb-") { return "computermouse" }
        return "dot.radiowaves.left.and.right"
    }
}

enum BatteryScanner {
    static func scan() -> [ScanBatch] {
        [ScanBatch(.registry, read: registry), ScanBatch(.bluetooth, read: BluetoothScanner.scan),
         ScanBatch(.receiver, read: ReceiverScanner.scan)]
    }

    private static func registry() throws -> [Peripheral] {
        var iterator: io_iterator_t = 0
        let match = ["IOPropertyExistsMatch": "BatteryPercent"] as CFDictionary
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, match, &iterator)
        guard status == KERN_SUCCESS else { throw NSError(domain: NSMachErrorDomain, code: Int(status)) }
        defer { IOObjectRelease(iterator) }
        var devices: [String: Peripheral] = [:]
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard property("Built-In") as? Bool != true,
                  let name = property("Product") as? String ?? property("DeviceName") as? String,
                  let level = property("BatteryPercent") as? Int, (0...100).contains(level) else { continue }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS else { continue }
            let transport = property("Transport") as? String ?? "HID"
            let isBluetooth = transport.localizedCaseInsensitiveContains("bluetooth")
            let address = property("DeviceAddress") as? String ?? property("SerialNumber") as? String
            let id = BluetoothScanner.addressID(isBluetooth ? address : property("DeviceAddress") as? String)
                ?? "registry-\(entryID)"
            devices[id] = Peripheral(id: id, name: name, transport: isBluetooth || id.hasPrefix("bluetooth-") ? "蓝牙" : transport,
                                     percent: level, charging: property("IsCharging") as? Bool)
            if let serial = property("SerialNumber") as? String, !serial.isEmpty, !id.hasPrefix("bluetooth-") {
                devices[id]?.aliasKey = "hid-\(property("VendorID") as? Int ?? 0)-\(name)-\(serial)"
            }
        }
        return devices.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}
