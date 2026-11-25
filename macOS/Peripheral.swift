import Foundation
import IOKit
import IOKit.hid

struct Peripheral: Identifiable {
    let id: String
    let name: String
    let transport: String
    var percent: Int?
    var charging: Bool?
    var state = "已连接"

    var componentLevels = ""
    var bluetoothType: String?

    var statusText: String {
        if transport == "蓝牙" {
            var parts = [transport]
            if charging == true { parts.append("充电中") }
            if state != "已连接" { parts.append(state) }
            if !componentLevels.isEmpty { parts.append(componentLevels) }
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
    static func scan() throws -> [Peripheral] {
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
        }
        for var row in BluetoothScanner.scan() {
            if let existing = devices[row.id] {
                row.percent = row.percent ?? existing.percent
                row.charging = existing.charging
            }
            devices[row.id] = row
        }
        for receiver in ReceiverScanner.scan() { devices[receiver.id] = receiver }
        return devices.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }
}
